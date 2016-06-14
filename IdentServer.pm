package IdentServer;

use IO::Socket;
use Log::Log4perl;
use IPC::Shareable;

use constant MAXCLIENTS => 100;

our $pidFile = '/var/run/identd.pid';

sub new {
  my ($class, $self) = @_;
  $self->{'logger'} = getLogger();
  return bless $self, $class;
}

# signal handler
sub setSigHandler {
  my ($self) = @_;
  foreach my $sig('INT','ABRT','TERM','QUIT'){
    $SIG{$sig}=sub{
      if($self->{listen_socket}) {
        $self->{listen_socket}->close();  #close master socket
      }
      $self->{'logger'}->info("Got $sig signal. Removing pid file and exiting...");
      # remove the pid file
      unlink $pidFile;
      # and exit
      exit(1);
    };
  }
  
  $SIG{CHLD} = 'IGNORE';  # reap all children as they complete
}

# initialize logger
sub getLogger {
  my $log_conf = {
    "log4perl.rootLogger" => "DEBUG, LOGFILE",
    "log4perl.appender.LOGFILE" => "Log::Log4perl::Appender::File",
    "log4perl.appender.LOGFILE.filename"  => "/var/log/identd.log",     # log file path
    "log4perl.appender.LOGFILE.mode" => "append",
    "log4perl.appender.LOGFILE.layout" => "Log::Log4perl::Layout::PatternLayout",
    "log4perl.appender.LOGFILE.layout.ConversionPattern" => "%d %p %m %n",
  };
  Log::Log4perl::init($log_conf) or warn 'Cannot initialize logger.';
  return Log::Log4perl->get_logger();
}

# get all the users on the system
sub getAllUsers {
  my ($self) = @_;
  my $uname;
  my @users=();
  
  while( ($uname) = getpwent() ) {
    push @users, $uname;
  }
  
  return @users;
}

# main public side method
sub startServer {
  my ($self) = @_;
  $self->setSigHandler();
  
  # client counter which is read/write shared scalar between processes
  my $parentHandle = tie my $client, 'IPC::Shareable', 'cntr', { create => 'true' } or $self->{logger}->logdie("Cannot create shared variable: $!");
  $client = 0;
  
  # if random mode then read all the users and share it with child processes
  my @users=();
  if($self->{'random'}) {
    # the array used for read only operation by child processes
    tie @users, 'IPC::Shareable', 'usrs', { create => 'true' } or $self->{logger}->logdie("Cannot create shared variable: $!");
    @users = $self->getAllUsers();
  }
  
  $self->startListening();    # set up master socket
  
  my $client_socket;      # connection socket
  # daemon starts here to listen for incoming connections
  while( $client_socket = $self->{listen_socket}->accept() ) {
    
    if($client >= MAXCLIENTS) {
      # close the connection, if it goes more than high limit
      $client_socket->close();
      $self->{logger}->info("Too many connections");
      next;
    }
    # increment client counter
    $parentHandle->shlock;
    $client++;
    $parentHandle->shunlock;

    # start child process to handle connection
    if(!fork()) {
      # child process
      $self->replyClient($client_socket);
    } else {
      # parent process
      $client_socket->close();
      $self->{logger}->debug("There are $client connections");
    }
  }
}

sub validateClientData {
  my ($self, $data) = @_;
  $data =~ s/^\s+//; #remove leading spaces
  $data =~ s/\s+$//; #remove trailing spaces
  if ($data =~ /^([+-]?[0-9]+)\s*\,\s*([+-]?[0-9]+)$/){   #stricly follow the request pattern as per RFC
    my $server_port=int($1);   #store int value server port for future use
    my $client_port=int($2);   #store int client port for future use
    return ($server_port, $client_port);
  }
  return ();  #not valid data
}

sub replyClient {
  my ($self, $socket) = @_;
  my $pid = $$;
  my $peerAddress = $socket->peerhost();
  my $peerPort = $socket->peerport();
  
  $self->{logger}->debug("[$pid] Got connection from client $peerAddress:$peerPort");
  
  my $data;
  while($data=<$socket>) {
    if( my ($server_port, $client_port) = $self->validateClientData($data) ) {
      
      my $reply;
      if ($server_port < 1 || $client_port < 1 || $server_port>65535 || $client_port>65535){  
        $reply= "$server_port, $client_port : ERROR : INVALID-PORT\n";         #non-integer will be taken as integer
        $socket->send($reply);
        last;
      }
      
      # if input is ok then reply according to mode
      if($self->{'random'}) {
        tie my @users, 'IPC::Shareable', 'usrs', { create => 'true' } or $self->{logger}->logdie("Cannot create shared variable: $!");
        my $index = int(rand(scalar @users));
        $reply="$server_port, $client_port : USERID : UNIX : $users[$index]\n";
      } elsif($self->{'uid'}) {
        my $username = getpwuid($client_port);
        if($username) {
          $reply="$server_port, $client_port : USERID : UNIX : $username\n";
        } else {
          $reply="$server_port, $client_port : ERROR : NO-USER\n";
        }
      } elsif($self->{'always'}) {
        $reply="$server_port, $client_port : USERID : UNIX : $self->{'always'}\n";
      }
      $socket->send($reply);
      last;
      
    } else {
      # should drop client without any reply
      last;
    }
    
  }
  
  $self->{logger}->debug("[$pid] Closing connection of client $peerAddress:$peerPort");
  $socket->close();
  
  # decrement client counter
  my $childHandle = tie my $client, 'IPC::Shareable', 'cntr', { create => 'true' } or $self->{logger}->logdie("Cannot create shared variable: $!");
  $childHandle->shlock;
  $client--;
  $childHandle->shunlock;
  
  exit(0);    #child exits here
}

sub startListening {
  # prepare master socket to listen
  my ($self) = @_;
  $self->{listen_socket} = new IO::Socket::INET (
        LocalPort => 113,
        Proto => 'tcp',
        Listen => 10,
        Reuse => 1,
    ) or $self->{'logger'}->logdie("ERROR in Socket Creation : $!");
    
  my $mode = $self->findMode();
  $self->{'logger'}->info("Identd server started in $mode mode...");
}

# helper function to find out which mode we are in
sub findMode {
  my ($self) = @_;
  if($self->{'random'}){
    return 'random';
  } elsif ($self->{'uid'}) {
    return 'uid';
  } else {
    return 'always';
  }
}

1;
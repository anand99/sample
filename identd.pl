#!/usr/local/bin/perl

use strict;
use warnings;
use Getopt::Long;
use POSIX qw(setsid);
use IdentServer;

# the main function which calls other functions
sub main {
  # first get the arguments and its validation
  my $options = getArgs();
  
  # this script need to run by sudo. We are listening on port 113 and using some directories which requires sudo access
  if($> != 0) {
    print("Please run this script as root.\n");
    return 1;
  }
  
  if($options->{kill}) {
    # killing the server based on pid file
    if(-e $IdentServer::pidFile) {
      my $tpid = getPid();      # read the pid from file
      kill 'TERM', $tpid;       # send Term signal
      print("Ident server($tpid) killed.\n");
      return 0;
    } else {
      print("There is no Ident server running.\n");
      return 1;
    }
  }
  
  if(-e $IdentServer::pidFile) {
    # this means the server is running we should not start new one
    my $pid = getPid();
    print("The server is already running with PID: $pid \n");
    return 1;
  }
  
  # daemonize the process and start server
  startDaemon($options);
  
  return 0;
}

# read the pid of server from file
sub getPid {
    open(my $fh, "<", "$IdentServer::pidFile") or die "cannot open the pid file";
    my $pid = <$fh>;
    chomp($pid);
    close $fh;
    return $pid;
}

# daemonize the process and initiate server from IdentServer class
sub startDaemon {
  my ($options) = @_;
  chdir '/';
  umask 0;
  
  close STDIN;
  close STDOUT;
  close STDERR;
  
  my $pid = fork();
  exit if $pid;     #parent exit here

  setsid();
  my $proc = $$;
  my $daemon = IdentServer->new($options);        # create object of IdentServer
  $daemon->{'logger'}->info("Opening $IdentServer::pidFile to write pid");
  open (my $fh, ">", "$IdentServer::pidFile") or die "Cannot open file for writing pid";
  $daemon->{'logger'}->info("Writing pid to the file");
  print $fh $proc;
  close($fh);
  
  $daemon->startServer();
}

# this function will read command line arguments and do some validation
sub getArgs {
  my ($random, $myUID, $myName, $kill, $help);
  my $cmd = GetOptions ('r|random' => \$random,
              'u|uid' => \$myUID,
              'a|always=s' => \$myName,
              'k|kill' => \$kill,
              'h|help' => \$help);

  # if no valid commandline given
  if(!$cmd) {
    usage();
    exit(1);
  }
  
  if($help) {
    usage();
    exit(0);
  }
  
  # check whether the user has provided more than one option
  if(($random and $myUID) or ($myUID and $myName) or ($myName and $random)){
    print "Please use only one of the option from random, uid and always.\n";
    exit(1);
  }
  
  # if user hasn't provided any option use random by default
  if(!$random and !$myUID and !$myName){
     $random=1;
  }   
              
  return {
    'kill' => $kill,
    'random' => $random,
    'always' => $myName,
    'uid' => $myUID,
  };
}

sub usage {
  print <<"EOF";

Usage: identd.pl [options]
Run identd program similar to RFC1413 with some changes.
--random, -r         Replies with the username of a randomly-chosen Unix user on the
                     host running your program.
--uid, -u            Replies with the username of the user whose UID is equal to the
                     "client port" parameter specified by the ident client. If there is no
                     user matching the requested UID, the program should reply with an RFC
                     1413 compliant "NO-USER" error.
--always, -a <name>  Always replies with the specified name.
--kill, -k           Kill the server if it is running.
--help, -h           Print usage information.

Please read the log file /var/log/identd.log once the server started for more information.
Also you need to run this script as super-user/root.

EOF
}

exit(main()) unless caller;

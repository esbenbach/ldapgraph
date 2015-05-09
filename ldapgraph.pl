#!/usr/bin/perl -aw

#### This Program retrives information from the OpenLDAP Monitor backend and places them in rrd files.
#### The tool ldapgraph.cgi can be used to present graphs in a webpage - however it is only provided as an example and not that much maintained.

# Parts of this code is based on the mailgraph rrd frontend by David Schweikert <dws@ee.ethz.ch>
# and on the ldapmon code posted to the openldap mailinglist by Unknown <UNKNOWN>
#
# Note: I can't figure out who posted the original code, if you know please let me know so i can give credits where they are due.

# Version 0.2a - Changed to daemon mode and integrated the ldapmon tool into the main daemon
# Version 0.1  - Initial Ldapgraph implementation - should be run from cron

use strict;
use Net::LDAP;
use Net::LDAP::Util qw(ldap_error_name ldap_error_text);
use POSIX;
use Time::Local;
use RRDs;
use Getopt::Long;
use Config::General;

# Version info
my $version= '0.2a';

# Production or Development?
my $production = 1;

#######################################
#           MONITOR VARIABLES         #
#######################################

# Lets get the program name
my @prog = split(/\//,$0);
my $prog = pop @prog;

# Variable for the LDAP Connection handle
my $ldap;

# Monitor dn - replace with config reading sometime
my $baseDN = "cn=Monitor";

# Basic search spaces - replace with configuration reading at some point
my $statsDN = "cn=Statistics,$baseDN";
my $operationsDN = "cn=Operations,$baseDN";
my $connectionsDN = "cn=Connections,$baseDN";

# Search spaces for interessting counters - replace with config reading at some point
my $bytesDN = "cn=Bytes,$statsDN";
my $pduDN = "cn=PDU,$statsDN";
my $entriesDN = "cn=Entries,$statsDN";
my $completedBindsDN = "cn=Bind,$operationsDN";
my $completedUnBindsDN = "cn=Unbind,$operationsDN";
my $completedAddsDN = "cn=Add,cn=Operations,cn=Monitor";
my $completedDelsDN = "cn=Delete,$operationsDN";
my $completedModrdnsDN = "cn=Modrdn,$operationsDN";
my $completedModsDN = "cn=Modify,$operationsDN";
my $completedSearchsDN = "cn=Search,$operationsDN";
my $totalConnectionsDN = "cn=Total,$connectionsDN";
my $currentConnectionsDN = "cn=Current,$connectionsDN";
my $readWaitersDN = "cn=Read,cn=Waiters,cn=Monitor";

##########################################
#           RRDRELATED VARIABLES         #
##########################################

# rrd File name
my $rrdfile;
# rrd stepping
my $rrdstep = 300;
my $xpoints = 540;
my $points_per_sample = 3;

# Simple time variables
my $year;
my $minute;


#######################################
#           GENERAL VARIABLES         #
#######################################

# Locations
my $daemon_logfile = '';
my $daemon_rrd_dir = '';
my $config_file = '';
if($production)
{
    $daemon_logfile = '/var/log/ldapgraph.log';
    $daemon_rrd_dir = '/var/lib/ldapgraph/';
    $config_file = '/var/lib/ldapgraph/ldapgraph.conf'
}

# Hash map for commandline options
my %opt = ();

# Signals to Trap and Handle
$SIG{'INT' } = 'interrupt';
$SIG{'HUP' } = 'interrupt_hup';
$SIG{'ABRT'} = 'interrupt';
$SIG{'QUIT'} = 'interrupt';
$SIG{'TRAP'} = 'interrupt';
$SIG{'STOP'} = 'interrupt';
$SIG{'TERM'} = 'interrupt';


#####################################
#	   READ CONFIGURATIONS	    #
#####################################

my %config;
sub readconfig
{
	my $conf = new Config::General($config_file);
	%config  = $conf->getall;
}

# Interrupt: Extremely simple interrupt handler
sub interrupt()
{
	print "caught @_ exiting\n";
	exit;
}

# Handler for the HUP signal
sub interrupt_hup()
{
  print "Caught @_ signal reloading config\n";
  readconfig;
}

# Help: Information about how to call this daemon
sub help(){
  print "Help not written, but options are version, help, debug, daemonized and verbose \n";
  exit;
}

# OptionHandling: Function for handling command line options
sub optionHandling()
{
  Getopt::Long::Configure('no_ignore_case');
  GetOptions(\%opt, 'help|h', 'version|V', 'debug', 'daemonized|d', 'verbose|v') or exit(1);

  # Display help if option line help is used
  help() if $opt{help};

  # Display version if option version is used
  if ($opt{version}) {
    print "ldapgraph $version by esben\@ofn.dk";
    exit;
  }
}

# Daemonize: Daemonizes the application
sub daemonize {
  chdir($daemon_rrd_dir)       or die "Can't chdir to $daemon_rrd_dir: $!";
  open STDIN,  '>>/dev/null'   or die "Can't read /dev/null: $!";
  open STDOUT, '>>' .$daemon_logfile   or die "Can't write to /dev/null: $!";
  open STDERR, '>>' .$daemon_logfile   or die "Can't write to /dev/null: $!";
  defined(my $pid = fork)      or die "Can't fork: $!";
  exit if $pid;
  setsid                       or die "Can't start a new session: $!";
  umask 0;
}

# getMonitorDesc: Retrives the information from ldap datatree
sub getMonitorDesc
{
  my $dn = $_[0];
  my $attr = $_[1];
  if (!$attr) { $attr = "description"};
  print "$dn\n" if $opt{debug};
  print "$attr\n" if $opt{debug};
  my $searchResults = $ldap->search(base => "$dn",
                                    scope => 'base',
                                    filter => 'objectClass=*',
                                    attrs => ["$attr"],);
  my $entry = $searchResults->pop_entry() if $searchResults->count() == 1;
  return $entry->get_value("$attr");
}

# ldapmonitoring: Retrives values from the ldap monitor
sub ldapmonitoring
{

    my $serverNumber = shift;

    my $host = $config{'server'}[$serverNumber];
    my $port = $config{'port'}[$serverNumber];
    my $bindPW = $config{'bindpw'}[$serverNumber];
    my $bindDN = $config{'binddn'}[$serverNumber];

    print $host . "\n" if $opt{debug};
    print $bindPW . "\n" if $opt{debug};
    print $bindDN . "\n" if $opt{debug};
    
    if ($ldap = Net::LDAP->new("$host", port=> "$port", version =>3, timeout => 10)){
	print "Succesfully created socket to host: $host\n" if $opt{debug};
    }
    else
    {
	print "Cannot create socket to $host\n"; 
	return 0;
    }

    # Attempt to connect to the ldap host.
    my $bindResult;
    if (defined $bindDN and defined $bindPW)
    {
	$bindResult = $ldap->bind($bindDN, password => $bindPW);
	print "Succefully bound using $bindDN and $bindPW\n" if $opt{debug};
    }
    else
    {
	$bindResult = $ldap->bind();
    }
   
    if ($bindResult->is_error()) {
	print
	    "Authentication failed.\n",
	    return 0;
    }


# Hash map for the values read from the monitor backend.
    my %monValues = (
		     bytes => '',
		     read  => '',
		     operations => '',
		     entries => '',
		     totalcon => '',
		     curcon => '',
		     pdu => '',
		     unbind => '',
		     bind => '',
		     adds => '',
		     deletes => '',
		     modrdns => '',
		     mods => '',
		     searches => '',
		     bytes => ''
		    );
    
    if ($opt{debug}) {
      print "Binds: " . getMonitorDesc("$completedBindsDN", "monitorOpCompleted"), "\n";
      print "UnBinds: " . getMonitorDesc("$completedUnBindsDN", "monitorOpCompleted"), "\n";
      print "Completed Operations: " . getMonitorDesc("$operationsDN", "monitorOpCompleted"), "\n";
      print "Searches " . getMonitorDesc("$completedSearchsDN", "monitorOpCompleted"), "\n";
      print "Total connections: " . getMonitorDesc("$totalConnectionsDN", "monitorCounter"), "\n";
      print "Outgoing PDUs: " . getMonitorDesc("$pduDN", "monitorCounter"), "\n";
      print "Entries: " . getMonitorDesc("$entriesDN", "monitorCounter"), "\n";
      print "Adds: " . getMonitorDesc("$completedAddsDN", "monitorOpCompleted"), "\n";
      print "Deletes: " . getMonitorDesc("$completedDelsDN", "monitorOpCompleted"), "\n";
      print "Mods: " . getMonitorDesc("$completedModsDN", "monitorOpCompleted"), "\n";
      print "Modrdns: " . getMonitorDesc("$completedModrdnsDN", "monitorOpCompleted"), "\n";
      print "Current connections: " . getMonitorDesc("$currentConnectionsDN", "monitorCounter"), "\n";
      print "Bytes handled: " . getMonitorDesc("$bytesDN", "monitorCounter")."\n";
      print "Read-Wait: " . getMonitorDesc("$readWaitersDN", "monitorCounter")."\n";
    }
    
    $monValues{'bind'} = getMonitorDesc("$completedBindsDN", "monitorOpCompleted");
    $monValues{'unbind'} = getMonitorDesc("$completedUnBindsDN", "monitorOpCompleted");
    $monValues{'operations'} = getMonitorDesc("$operationsDN", "monitorOpCompleted");
    $monValues{'searches'} = getMonitorDesc("$completedSearchsDN", "monitorOpCompleted");
    $monValues{'totalcon'} = getMonitorDesc("$totalConnectionsDN", "monitorCounter");
    $monValues{'pdu'} = getMonitorDesc("$pduDN", "monitorCounter");
    $monValues{'bytes'} = getMonitorDesc("$bytesDN", "monitorCounter");
    $monValues{'entries'} = getMonitorDesc("$entriesDN", "monitorCounter");
    $monValues{'read'} = getMonitorDesc("$readWaitersDN", "monitorCounter");
    $monValues{'adds'} = getMonitorDesc("$completedAddsDN", "monitorOpCompleted");
    $monValues{'mods'} = getMonitorDesc("$completedModsDN", "monitorOpCompleted");
    $monValues{'modrdns'} = getMonitorDesc("$completedModrdnsDN", "monitorOpCompleted");
    $monValues{'curcon'} = getMonitorDesc("$currentConnectionsDN", "monitorCounter");
    $monValues{'deletes'} = getMonitorDesc("$completedDelsDN", "monitorOpCompleted");
    
    
    $bindResult = $ldap->unbind;
    if ($bindResult->is_error()){
      print "An error occured while unbinding: $_\n";
    }
    
    $ldap->disconnect();
    
    return %monValues;
  }

sub setupRRD($)
{
  my $start_time = shift;
  my $rows = $xpoints/$points_per_sample;
  my $realrows = int($rows*1.1); # ensure that the full range is covered
  my $day_steps = int(3600*24 / ($rrdstep*$rows));
  # use multiples, otherwise rrdtool could choose the wrong RRA
  my $week_steps = $day_steps*7;
  my $month_steps = $week_steps*5; #Not strictly correct - 5 week summizes, will be broken after many years, not really a problem if we only want one years history
  my $year_steps = $month_steps*12;
  
  my $heartbeat = $rrdstep*2;
  
  # rrd definition
  if(! -f $rrdfile) {
    RRDs::create($rrdfile, '--start', $start_time, '--step', $rrdstep,
		 'DS:curcon:GAUGE:'.($heartbeat).':0:U',
		 'DS:totalcon:DERIVE:'.($heartbeat).':0:U',
		 'DS:pdus:DERIVE:'.($heartbeat).':0:U',
		 'DS:binds:DERIVE:'.($heartbeat).':0:U',
		 'DS:unbinds:DERIVE:'.($heartbeat).':0:U',
		 'DS:adds:DERIVE:'.($heartbeat).':0:U',
		 'DS:deletes:DERIVE:'.($heartbeat).':0:U',
		 'DS:modrdns:DERIVE:'.($heartbeat).':0:U',
		 'DS:mods:DERIVE:'.($heartbeat).':0:U',
		 'DS:searches:DERIVE:'.($heartbeat).':0:U',
		 'DS:bytes:DERIVE:'.($heartbeat).':0:U',
		 'DS:entries:DERIVE:'.($heartbeat).':0:U',
		 'DS:operations:DERIVE:'.($heartbeat).':0:U',
		 'DS:read:GAUGE:'.($heartbeat).':0:U',
		 "RRA:AVERAGE:0.5:$day_steps:$realrows",   # day
		 "RRA:AVERAGE:0.5:$week_steps:$realrows",  # week
		 "RRA:AVERAGE:0.5:$month_steps:$realrows", # month
		 "RRA:AVERAGE:0.5:$year_steps:$realrows",  # year
		 "RRA:MAX:0.5:$day_steps:$realrows",   # day
		 "RRA:MAX:0.5:$week_steps:$realrows",  # week
		 "RRA:MAX:0.5:$month_steps:$realrows", # month
		 "RRA:MAX:0.5:$year_steps:$realrows",  # year
		);
    $minute = $start_time;

    my $rrd_error = RRDs::error;
    die "Error while creating $rrdfile: $rrd_error\n" if $rrd_error;

  }
  elsif(-f $rrdfile) {
    $minute = RRDs::last($rrdfile) + $rrdstep;
    my $rrd_error=RRDs::error;
    die "ERROR while updating $rrdfile : $rrd_error\n" if $rrd_error;
  }

}

sub update
{
	my ($t,$rrdfile,%monValues) = @_;

	my $m = $t - $t%$rrdstep;

	if (defined $monValues{'bind'} )
	{
		print "update $minute:$monValues{curcon}:$monValues{totalcon}:$monValues{pdu}:$monValues{bind}:$monValues{unbind}:$monValues{adds}:$monValues{deletes}:$monValues{modrdns}:$monValues{mods}:$monValues{searches}:$monValues{bytes}:$monValues{entries}:$monValues{operations}:$monValues{read}\n" if $opt{verbose};
		RRDs::update $rrdfile, "$minute:$monValues{curcon}:$monValues{totalcon}:$monValues{pdu}:$monValues{bind}:$monValues{unbind}:$monValues{adds}:$monValues{deletes}:$monValues{modrdns}:$monValues{mods}:$monValues{searches}:$monValues{bytes}:$monValues{entries}:$monValues{operations}:$monValues{read}";
		my $rrd_error=RRDs::error;
		print "ERROR while updating $rrdfile: $rrd_error\n" if $rrd_error;
	}

	if($m > $minute + $rrdstep or not defined $monValues{'bind'}) {
		for(my $sm = $minute + $rrdstep;$sm < $m;$sm += $rrdstep) {
			print "update $sm:0:0:0:0:0:0:0:0:0:0:0:0:0:0 (SKIP)\n" if $opt{verbose};
			RRDs::update $rrdfile, "$sm:0:0:0:0:0:0:0:0:0:0:0:0:0:0";
			my $rrd_error=RRDs::error;
			die "ERROR while updating $rrdfile: $rrd_error\n" if $rrd_error;
		}
	}
	$minute = $m;

	return 1;
}


sub main
{
  # Start by handling options and figure out if we need to quit or not, daemonize or whatever.
  optionHandling();

  chdir $daemon_rrd_dir or die "mailgraph: can't chdir to $daemon_rrd_dir: $!";
  -w $daemon_rrd_dir or die "mailgraph: can't write to $daemon_rrd_dir\n";

  #Should the program be daemonized or should we just report to STDOUT?
  if( $opt{daemonized} )
  {
  	&daemonize;
  }

  # Read the configuration file for host options
  readconfig;

  # Get the number of defined servers
  # Ugly i know, but i don't know a better way!
  my $counter = 0;
  my $tmp = $config{'server'};
  my @tmparray = @$tmp;

  for ($counter = 0; $counter <= scalar(@tmparray)-1; $counter++) {
    #Make sure rrd file exist otherwise create it
    $rrdfile = $config{'server'}[$counter];
      if(! -f "$daemon_rrd_dir/$rrdfile") {
	setupRRD(time());
      }
    else {
      $minute = RRDs::last($rrdfile) + $rrdstep;
      my $rrd_error=RRDs::error;
      die "ERROR while updating $daemon_rrd_dir/$rrdfile: $rrd_error\n" if $rrd_error;
    }
  }

  my %monValues;
  # All parts of the monitor logic is done inside this while loop 
  while (1) {
    for ($counter = 0; $counter <= scalar(@tmparray)-1; $counter++) {
      print "Counter: " . $counter . "\n";
      # Actual monitoring

      ## If we have values from ldap for the particular server then store them in the hash, and write them to the rrd file
      ## using output of time() as timestamp
      if (%monValues = &ldapmonitoring($counter)) {
	if ( $opt{debug} ) {
	  while ( my ($key, $value) = each(%monValues) ) { 
	    print "$key => $value\n"; 
	  } 
	}
	
	update(time(),$config{'server'}[$counter],%monValues);
      }
    }
    
    # Sleep for 300 Seconds - Not a good schedule, but works perfectly for a small number of servers. And it is needed as we would otherwise use a lot of cpu cycles and filling the rrd log
    sleep(300);
  }
  
}

&main;

__END__

=head1 NAME

ldapgraph version 0.2a

=head1 DESCRIPTION

This script retrives values from the ldap monitor backend, and places them in an RRD file.
This rrd file can be used to graph performance for the ldap daemon.

=head1 COPYRIGHT

Copyright (c) 2007 by Esben Bach. All rights reserved. 

=head1 LICENSE

=head1 AUTHOR

S<Esben Bach E<lt>esben@ofn.dkE<gt>>

=cut

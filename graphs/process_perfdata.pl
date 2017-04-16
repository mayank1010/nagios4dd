#!/usr/bin/perl
# nagios: -epn
## pnp4nagios–0.6.17
## Copyright (c) 2005-2010 Joerg Linge (http://www.pnp4nagios.org)
##
## This program is free software; you can redistribute it and/or
## modify it under the terms of the GNU General Public License
## as published by the Free Software Foundation; either version 2
## of the License, or (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the Free Software
## Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.



if( $< == 0 ){
    print "dont try this as root \n";
    exit 1;
}

use warnings;
use strict;
use POSIX;
use Getopt::Long;
use RRDs;
use Fcntl ':flock';
use Time::HiRes qw(gettimeofday tv_interval);
use vars qw ( $TEMPLATE %NAGIOS $t0 $t1 $rt $delayed_write $rrdfile @ds_create $count $line $name $ds_update $dstype);

# Nagiosgraph Configuration 
my $naggraph_configfile = '/srv/app/nagiosgraph/etc/nagiosgraph.conf';
my %Naggraph_Config;

# PNp4Nagios Configuration 
my %conf = (
    TIMEOUT            => 15,
    CFG_DIR            => "/srv/app/pnp4nagios/etc/",
    USE_RRDs           => 1,
    RRDPATH            => "/srv/app/pnp4nagios/var/perfdata",
    RRDTOOL            => "/usr/bin/rrdtool",
    RRD_STORAGE_TYPE   => "SINGLE",
    RRD_HEARTBEAT      => 8640,
    RRA_STEP           => 60,
    RRA_CFG            => "/srv/app/pnp4nagios/etc/rra.cfg",
    STATS_DIR          => "/srv/app/pnp4nagios/var/stats",
    LOG_FILE           => "/srv/app/pnp4nagios/var/perfdata.log",
    LOG_FILE_MAX_SIZE  => "10485760",               #Truncate after 10MB
    LOG_LEVEL          => 0,
    XML_ENC            => "UTF-8",
    XML_UPDATE_DELAY   => 0,                        # Write XML only if file is older then XML_UPDATE_DELAY seconds
    RRD_DAEMON_OPTS    => "",
    GEARMAN_HOST       => "localhost:4730",                        # How many gearman worker childs to start 
    PREFORK            => 2,                        # How many gearman worker childs to start 
    REQUESTS_PER_CHILD => 20000,                   # Restart after a given count of requests
    ENCRYPTION         => 1,                       # Decrypt mod_gearman packets
    KEY                => 'should_be_changed',
    KEY_FILE           => '/srv/app/pnp4nagios/etc/secret.key',
    UOM2TYPE           => { 'c' => 'DERIVE', 'd' => 'DERIVE' },
);

my %const = (
    XML_STRUCTURE_VERSION => "4",
    VERSION               => "0.6.17",
);

#
# Dont change anything below these lines ...
#
#
# "rrdtool create" Syntax
#
my @default_rrd_create = ( "RRA:AVERAGE:0.5:1:2880", "RRA:AVERAGE:0.5:5:2880", "RRA:AVERAGE:0.5:30:4320", "RRA:AVERAGE:0.5:360:5840", "RRA:MAX:0.5:1:2880", "RRA:MAX:0.5:5:2880", "RRA:MAX:0.5:30:4320", "RRA:MAX:0.5:360:5840", "RRA:MIN:0.5:1:2880", "RRA:MIN:0.5:5:2880", "RRA:MIN:0.5:30:4320", "RRA:MIN:0.5:360:5840", );

Getopt::Long::Configure('bundling');
my ( $opt_d, $opt_V, $opt_h, $opt_i, $opt_n, $opt_b, $opt_gm, $opt_pidfile,$opt_daemon );
my $opt_t = $conf{TIMEOUT};                            # Default Timeout
my $opt_c = $conf{CFG_DIR} . "process_perfdata.cfg";
GetOptions(
    "V"          => \$opt_V,
    "version"    => \$opt_V,
    "h"          => \$opt_h,
    "help"       => \$opt_h,
    "i"          => \$opt_i,
    "inetd"      => \$opt_i,
    "b=s"        => \$opt_b,
    "bulk=s"     => \$opt_b,
    "d=s"        => \$opt_d,
    "datatype=s" => \$opt_d,
    "t=i"        => \$opt_t,
    "timeout=i"  => \$opt_t,
    "c=s"        => \$opt_c,
    "config=s"   => \$opt_c,
    "n"          => \$opt_n,
    "npcd"       => \$opt_n,
    "gearman:s"  => \$opt_gm,
    "daemon"     => \$opt_daemon,
    "pidfile=s"  => \$opt_pidfile,
);

parse_config($opt_c);
$conf{'GLOBAL_RRD_STORAGE_TYPE'} = uc($conf{'RRD_STORAGE_TYPE'}); # store the initial value for later use
$opt_t = $conf{TIMEOUT};    # Reset Timeout from config file

my %stats = init_stats();
my $cypher;

#
# RRDs Perl Module Detection
#
if ( $conf{USE_RRDs} == 1 ) {
    unless ( eval "use RRDs;1" ) {
        $conf{USE_RRDs} = 0;
    }
}

#
# Include Gearman modules if needed 
#
if ( defined($opt_gm) ) {
    unless ( eval "use Gearman::Worker;1" ) {
        print "Perl module Gearman::Worker not found\n";
        exit 1;
    }
    unless ( eval "use MIME::Base64;1" ) {
        print "Perl module MIME::Base64 not found\n";
        exit 1;
    }
    unless ( eval "use Crypt::Rijndael;1" ) {
        print "Perl module Crypt::Rijndael not found\n";
        exit 1;
    }
}

print_help()    if ($opt_h);
print_version() if ($opt_V);

init_signals();
my %children = ();       # keys are current child process IDs
my $children = 0;        # current number of children
if( ! defined($opt_gm) ){
    #
    # synchronos / bulk / npcd mode
    #
    main();
}else{
    #
    # Gearman worker main loop
    #
    print_log( "process_perfdata.pl-$const{VERSION} Gearman Worker Daemon", 0 );
    if($opt_gm =~ /:\d+/ ){
        $conf{'GEARMAN_HOST'} = $opt_gm;
    }
    if($conf{ENCRYPTION} == 1){
        print_log( "Encryptions is enabled", 0 );
        read_keyfile($conf{'KEY_FILE'});
        # fill key up to 32 bytes 
        $conf{'KEY'} = substr($conf{'KEY'},0,32) . chr(0) x ( 32 - length( $conf{'KEY'} ) );
        $cypher = Crypt::Rijndael->new( $conf{'KEY'}, Crypt::Rijndael::MODE_ECB() );
    }
    daemonize();
}

#
# Subs
#
# Main function to switch to the right mode.
sub main {
    my $job = shift;
    my $t0 = [gettimeofday];
    my $t1;
    my $rt;
    my $lines = 0;
    # Gearman Worker
    if (defined $opt_gm) {
        print_log( "Gearman Worker Job start", 1 );
        %NAGIOS = parse_env($job->arg);
        $lines = process_perfdata();
        $t1 = [gettimeofday];
        $rt = tv_interval $t0, $t1;
        $stats{runtime} += $rt;
        $stats{rows}++;
        if( ( int $stats{timet} / 60 ) < ( int time / 60 )){
            store_internals();
            init_stats();
        }
        print_log( "Gearman job end (runtime ${rt}s) ...", 1 );
        return 1;
    } elsif ( $opt_b && !$opt_n ) {
        # Bulk mode
    	alarm($opt_t);
        print_log( "process_perfdata.pl-$const{VERSION} starting in BULK Mode called by Nagios", 1 );
        $lines = process_perfdata_file();
    } elsif ( $opt_b && $opt_n ) {
        # Bulk mode with npcd
    	alarm($opt_t);
        print_log( "process_perfdata.pl-$const{VERSION} starting in BULK Mode called by NPCD", 1 );
        $lines = process_perfdata_file();
    } else {
        # Synchronous mode
	$opt_t = 5 if $opt_t > 5; # maximum timeout
    	alarm($opt_t);
        print_log( "process_perfdata.pl-$const{VERSION} starting in SYNC Mode", 1 );
        %NAGIOS = parse_env();
        $lines = process_perfdata();
    }
    $rt = tv_interval $t0, $t1;
    $stats{runtime} = $rt;
    $stats{rows} = $lines;
    store_internals();
    print_log( "PNP exiting (runtime ${rt}s) ...", 1 );
    exit 0;
}

#
# Parse %ENV and return a global hash %NAGIOS
#
sub parse_env {
    my $job_data = shift;
    %NAGIOS = ();
    $NAGIOS{DATATYPE} = "SERVICEPERFDATA";

    if(defined $opt_gm){
        # Gearman Worker
        $job_data = decode_base64($job_data);
        if($conf{ENCRYPTION} == 1){
            $job_data = $cypher->decrypt( $job_data )        
        }
        my @LINE = split(/\t/, $job_data);
        foreach my $k (@LINE) {
            $k =~ /([A-Z 0-9_]+)::(.*)$/;
            $NAGIOS{$1} = $2 if ($2);
        }
        if ( !$NAGIOS{HOSTNAME} ) {
            print_log( "Gearman job data missmatch. Please check your encryption key.", 0 );
            return %NAGIOS;
        }
	} elsif ( defined($opt_b) ){
		# Bulk Mode
        my @LINE = split(/\t/, $job_data);
        foreach my $k (@LINE) {
            $k =~ /([A-Z 0-9_]+)::(.*)$/;
            $NAGIOS{$1} = $2 if ($2);
        }
    }else{

 	    if ( ( !$ENV{NAGIOS_HOSTNAME} ) and ( !$ENV{ICINGA_HOSTNAME} ) ) {
            print_log( "Cant find Nagios Environment. Exiting ....", 1 );
            exit 2;
        }
        foreach my $key ( sort keys %ENV ) {
            if ( $key =~ /^(NAGIOS|ICINGA)_(.*)/ ) {
                $NAGIOS{$2} = $ENV{$key};
            }
        }

	}

    if ($opt_d) {
        $NAGIOS{DATATYPE} = $opt_d;
    }

    $NAGIOS{DISP_HOSTNAME}    = $NAGIOS{HOSTNAME};
    $NAGIOS{DISP_SERVICEDESC} = $NAGIOS{SERVICEDESC};
    $NAGIOS{HOSTNAME}         = cleanup( $NAGIOS{HOSTNAME} );
    $NAGIOS{SERVICEDESC}      = cleanup( $NAGIOS{SERVICEDESC} );
    $NAGIOS{PERFDATA}         = $NAGIOS{SERVICEPERFDATA};
    $NAGIOS{CHECK_COMMAND}    = $NAGIOS{SERVICECHECKCOMMAND};

    if ( $NAGIOS{DATATYPE} eq "HOSTPERFDATA" ) {
        $NAGIOS{SERVICEDESC}      = "_HOST_";
        $NAGIOS{DISP_SERVICEDESC} = "Host Perfdata";
        $NAGIOS{PERFDATA}         = $NAGIOS{HOSTPERFDATA};
        $NAGIOS{CHECK_COMMAND}    = $NAGIOS{HOSTCHECKCOMMAND};
    }
    print_log( "Datatype set to '$NAGIOS{DATATYPE}' ", 2 );
    return %NAGIOS;
}

#
# Perfdata sanity check
#
sub process_perfdata {
    if ( keys( %NAGIOS ) == 1 && defined($opt_gm) ) {
        $stats{skipped}++;
        return 1;
    }
    if ( ! defined($NAGIOS{PERFDATA}) && ! defined($opt_gm) ) {
        print_log( "No Performance Data for $NAGIOS{HOSTNAME} / $NAGIOS{SERVICEDESC} ", 1 );
        if ( !$opt_b ) {
            print_log( "PNP exiting ...", 1 );
            exit 3;
        }
    }

    if ( $NAGIOS{PERFDATA} =~ /^(.*)\s\[(.*)\]$/ ) {
        $NAGIOS{PERFDATA}      = $1;
        $NAGIOS{CHECK_COMMAND} = $2;
        print_log( "PNP4Nagios: Found Perfdata from Distributed Server $NAGIOS{HOSTNAME} / $NAGIOS{SERVICEDESC} ($NAGIOS{PERFDATA})", 1 );
    }
    else {
        print_log( "PNP4Nagios: Found Performance Data for $NAGIOS{HOSTNAME} / $NAGIOS{SERVICEDESC} ($NAGIOS{PERFDATA}) ", 1 );
    }

    $NAGIOS{PERFDATA} =~ s/,/./g;
    $NAGIOS{PERFDATA} =~ s/\s+=/=/g;
    $NAGIOS{PERFDATA} =~ s/=\s+/=/g;
    $NAGIOS{PERFDATA} .= " ";
    parse_perfstring( $NAGIOS{PERFDATA} );
    return 1;
}


# Nagiosgraph read the config file
#
sub naggraph_readconfig {
  print_log( "Nagiosgraph config file not found", 2) unless -r $naggraph_configfile;

  # Read configuration data
  open FH, $naggraph_configfile;
    while (<FH>) {
      s/\s*#.*//;    # Strip comments
      /^(\w+)\s*=\s*(.*?)\s*$/ and do {
        $Naggraph_Config{$1} = $2;
        naggraph_debug(5, "Config $1:$2");
      };
    }
  close FH;

  # If debug is set make sure we can write to the log file
  if ($Naggraph_Config{debug} > 0) {
     open LOG, ">>$Naggraph_Config{logfile}" or print_log( "Nagiosgraph cannot append to logfile $Naggraph_Config{logfile}", 2);
  }

  # Make sure rrddir exist and is writable
  unless ( -w $Naggraph_Config{rrddir} ) {
    mkdir $Naggraph_Config{rrddir};
    print_log( "Nagiosgraph rrd dir $Naggraph_Config{rrddir} not writable", 2) unless -w $Naggraph_Config{rrddir};
  }
}

# Nagiosgraph: Write debug information to log file
#
sub naggraph_debug {
  my($l, $text) = @_;
  if ( $l <= $Naggraph_Config{debug} ) {
    $l = qw(none critical error warn info debug)[$l];
    # Get a lock on the LOG file (blocking call)
    flock(LOG,LOCK_EX);
      print LOG scalar localtime() . ' $RCSfile: insert.pl,v $ $Revision: 1.25 $ '."$l - $text\n";
    flock(LOG,LOCK_UN);  #Unlock file
  }
}

# Nagiosgraph URL encoding
sub naggraph_urlencode {
  $_[0] =~ s/([\W])/"%" . uc(sprintf("%2.2x",ord($1)))/eg;
  return $_[0];
}

# Convert PNP4Nagios lines into Nagiosgraph lines
#
# host_perfdata: $LASTHOSTCHECK$||$HOSTNAME$||check-host-alive||$HOSTOUTPUT$||$HOSTPERFDATA$
# srvc_perfdata: $LASTSERVICECHECK$||$HOSTNAME$||$SERVICEDESC$||$SERVICEOUTPUT$||$SERVICEPERFDATA$
sub naggraph_convert {
  my $data = shift;
  my @d;
  my @fields = split(/\t/, $data);
  foreach my $k (@fields) {
    $k =~ /([A-Z 0-9_]+)::(.*)$/;
    if ($1 eq "TIMET") { $d[0] = $2; }
    if ($1 eq "HOSTNAME") { $d[1] = $2; }
    if ($1 eq "SERVICEDESC") { $d[2] = $2; }
    if ($1 eq "SERVICEPERFDATA" || $1 eq "HOSTPERFDATA") { $d[4] = $2; }
    if ($1 eq "SERVICEOUTPUT" || $1 eq "HOSTOUTPUT") { $d[3] = $2; }
}
  print_log( "Nagiosgraph formatted: $d[0]||$d[1]||$d[2]||$d[3]||$d[4]", 1 );
  return ( lastcheck    => $d[0],
           hostname     => $d[1],
           servicedescr => $d[2],
           output       => $d[3],
           perfdata     => $d[4],
         );
}

# Nagiosgraph: Create new rrd databases if necessary
sub naggraph_createrrd {
  my($host,$service,$start,$labels) = @_;
  my($f,$v,$t,$ds,$db);
  my($RRA_1min, $RRA_6min, $RRA_24min, $RRA_288min);
  my(@resolution);
  my $directory = $Naggraph_Config{rrddir};

  if (defined $Naggraph_Config{resolution} ) {
    @resolution=split(/ /, $Naggraph_Config{resolution});
    naggraph_debug(4, "resol=$resolution[0] - $resolution[1] - $resolution[2] - $resolution[3]");
  }

  if ( defined $resolution[0] ) {
    $RRA_1min = $resolution[0];
  } else {
    $RRA_1min = 600;
  }
  if ( defined $resolution[1] ) {
    $RRA_6min = $resolution[1];
  } else {
    $RRA_6min = 700;
  }
  if ( defined $resolution[2] ) {
    $RRA_24min = $resolution[2];
  } else {
    $RRA_24min = 775;
  }
  if ( defined $resolution[3] ) {
    $RRA_288min = $resolution[3];
  } else {
    $RRA_288min = 797;
  }

  $db = shift @$labels;
  # Check for separator ,  create filestructure
  if ($Naggraph_Config{dbseparator} eq "subdir") {
     $directory .=  "/" . $host;
     unless (-e $directory) {
        # Create host specific directories
        mkdir $directory;
        print_log ("Nagiosgraph RRD: Creating directory $directory", 1);
        die "$directory not writable" unless -w $directory;
     }
     # RRD Filename
     $f = naggraph_urlencode("${service}___${db}")  . '.rrd';
  }
  else {
     # Build filename for raditional separation
     naggraph_debug(5, "Files stored in single folder structure");
     $f = naggraph_urlencode("${host}_${service}_${db}") . '.rrd';
  }
  print_log ("Nagiosgraph RRD: Checking $directory/$f", 1);
  unless ( -e "$directory/$f" ) {
    $ds = "$directory/$f --start $start";
    for ( @$labels ) {
      ($v,$t) = ($_->[0],$_->[1]);
      my $u = $t eq 'DERIVE' ? '0' : 'U' ;
      $ds .= " DS:$v:$t:$Naggraph_Config{heartbeat}:$u:U";
    }
    $ds .= " RRA:AVERAGE:0.5:1:" . $RRA_1min;
    $ds .= " RRA:AVERAGE:0.5:6:" . $RRA_6min;
    $ds .= " RRA:AVERAGE:0.5:24:" . $RRA_24min;
    $ds .= " RRA:AVERAGE:0.5:288:" . $RRA_288min;
   naggraph_debug(1, "DS = $ds");

    my @ds = split /\s+/, $ds;
    print_log ("Nagiosgraph RRD: create the rrd data set $ds.", 1);
    RRDs::create(@ds);
    print_log ("Nagiosgraph RRD: Error creating RRD " . RRDs::error) if RRDs::error;
  }
  print_log( "Nagiosgraph RRD: Confirmed $directory/$f", 1);
  return $f;
}

# Update Nagiosgraph rrd files
sub naggraph_rrdupdate {
  my($file,$time,$values,$host) = @_;
  my($ds,$c);
  my $directory = $Naggraph_Config{rrddir};

  # Select target folder depending on config settings
  if ($Naggraph_Config{dbseparator} eq "subdir") {
    $directory .=  "/" . $host;
  }

  $ds = "$directory/$file $time";
  for ( @$values ) {
    $_->[2] ||= 0;
    $ds .= ":$_->[2]";
  }

  my @ds = split /\s+/, $ds;
  naggraph_debug(4, "RRDs::update ". join ' ', @ds);
  RRDs::update(@ds);
  if (RRDs::error) {
    print_log ("Nagiosgraph RRD: update ERROR " . RRDs::error, 1);
  } else {
    print_log ("Nagiosgraph RRD: Updated $directory/$file $time", 1);
  }
}

# Dump to log the files read from Nagios
#
sub naggraph_dumpperfdata {
  my %P = @_;
  for ( keys %P ) {
    naggraph_debug(4, "Input $_:$P{$_}");
  }
}

#
# Process Perfdata in Bulk Mode
#
sub process_perfdata_file {
    if ( $opt_b =~ /-PID-(\d+)/ ) {
        print_log( "Oops: $opt_b already processed by $1 - please check timeout settings", 0 );
    }

    print_log( "searching for $opt_b", 2 );
    if ( -e "$opt_b" ) {
        my $pdfile = "$opt_b" . "-PID-" . $$;
        print_log( "renaming $opt_b to $pdfile for bulk update", 2 );
        unless ( rename "$opt_b", "$pdfile" ) {
            print_log( "ERROR: rename $opt_b to $pdfile failed", 1 );
            exit 4;
        }

        print_log( "reading $pdfile for bulk update", 2 );
        open( PDFILE, "< $pdfile" );
        my $count = 0;
        while (<PDFILE>) {
			my $job_data = $_;
            $count++;
            print_log( "Processing Line $count", 2 );
            my @LINE = split(/\t/);
            %NAGIOS = ();    # cleaning %NAGIOS Hash
            #foreach my $k (@LINE) {
            #    $k =~ /([A-Z 0-9_]+)::(.*)$/;
            #    $ENV{ 'NAGIOS_' . $1 } = $2 if ($2);
            #}
            parse_env($job_data);
            if ( $NAGIOS{SERVICEPERFDATA} || $NAGIOS{HOSTPERFDATA} ) {
               #########################################################
               # Start processing the information for PNP4Nagios
               #########################################################
               process_perfdata();

               #########################################################
               # Start processing the information for Nagiosgraph
               #########################################################
               print_log( "Nagiosgraph RRD: start processing line: $count", 2 );
               my $pnp4nagios_line = $_;
               naggraph_readconfig();
               # Read the Nagiosgraph map file 
               # define a subroutine that parses performance data
               my($naggraph_rules);
               open FH, $Naggraph_Config{mapfile};
               while (<FH>) {
                 $naggraph_rules = $naggraph_rules.$_;
               }
               close FH;

               $naggraph_rules = '
               sub naggraph_evalrules {
                 $_=$_[0];
                 my @s;
                 no strict "subs";
               ' . $naggraph_rules . '
                 use strict "subs";
                 print_log ("Nagiosgraph RRD: no map match for $job_data", 1) unless @s;
                 return \@s;
               }';

               undef $@;
               eval $naggraph_rules;
               print_log( "Nagiosgraph RRD: map file eval error: $@", 1 ) if $@;
 
               my %P = naggraph_convert($pnp4nagios_line);

               my $parsedata="servicedescr:$P{servicedescr}\noutput:$P{output}\nperfdata:$P{perfdata}";
               my $labels = naggraph_evalrules($parsedata);
               for my $s ( @$labels ) {
                 my $rrd = naggraph_createrrd($P{hostname}, $P{servicedescr}, $P{lastcheck}-1, $s);
                 naggraph_rrdupdate($rrd, $P{lastcheck}, $s, $P{hostname});
               }
               if (fileno(LOG)) { close LOG; }
               print_log( "Nagiosgraph RRD: end processing line: $count", 2 );
               #########################################################
               # End processing the information for Nagiosgraph
               #########################################################

            } else {
                print_log( "No Perfdata. Skipping line $count", 2 );
                $stats{skipped}++;
            }
        }

        print_log( "$count lines processed", 1 );

        if ( unlink("$pdfile") == 1 ) {
            print_log( "$pdfile deleted", 1 );
        }else {
            print_log( "Could not delete $pdfile:$!", 1 );
        }
    return $count;
    }
    else {
        print_log( "ERROR: File $opt_b not found", 1 );
    }
}

#
# Write Data to RRD Files
#
sub data2rrd {

    my @data      = @_;
    my @rrd_state = ();
    my $rrd_storage_type;

    print_log( "data2rrd called", 2 );
    $NAGIOS{XMLFILE}          = $conf{RRDPATH} . "/" . $data[0]{hostname} . "/" . $data[0]{servicedesc} . ".xml";
    $NAGIOS{SERVICEDESC}      = $data[0]{servicedesc};
    $NAGIOS{DISP_SERVICEDESC} = $data[0]{disp_servicedesc};
    $NAGIOS{AUTH_SERVICEDESC} = $data[0]{auth_servicedesc} || "";
    $NAGIOS{AUTH_HOSTNAME}    = $data[0]{auth_hostname} || "";
    $NAGIOS{MULTI_PARENT}     = "";
    $NAGIOS{MULTI_PARENT}     = $data[0]{multi_parent} || "";
    $TEMPLATE                 = $data[0]{template};

    unless ( -d "$conf{RRDPATH}" ) {
        unless ( mkdir "$conf{RRDPATH}" ) {
            print_log( "mkdir $conf{RRDPATH}, permission denied ", 1 );
            print_log( "PNP exiting ...",                          1 );
            exit 5;
        }
    }

    unless ( -d "$conf{RRDPATH}/$NAGIOS{HOSTNAME}" ) {
        unless ( mkdir "$conf{RRDPATH}/$NAGIOS{HOSTNAME}" ) {
            print_log( "mkdir $conf{RRDPATH}/$NAGIOS{HOSTNAME}, permission denied ", 1 );
            print_log( "PNP exiting ...",                                            1 );
            exit 6;
        }
    }

    #
    # Create PHP Template File
    #
    open_template( $NAGIOS{XMLFILE} );

    @ds_create = ();
    $ds_update = '';

    for my $i ( 0 .. $#data ) {
        print_log( " -- Job $i ", 3 );
        my $DS = $i + 1;

        #
        # for each datasource
        #
        for my $job ( sort keys %{ $data[$i] } ) {
            if ( defined $data[$i]{$job} ) {
                print_log( "  -- $job -> $data[$i]{$job}", 3 );
            }
        }

        if ( uc($conf{'GLOBAL_RRD_STORAGE_TYPE'}) eq "MULTIPLE" ) {
            my $file = $conf{RRDPATH} . "/" . $data[$i]{hostname} . "/" . $data[$i]{servicedesc} . ".rrd";
            if ( -e $file ){
                print_log("RRD_STORAGE_TYPE=MULTIPLE ignored because $file exists!", 1 ) if $i == 0;
                $data[$i]{rrd_storage_type} = "SINGLE";
            }
        }

		if ( $i == 0 ){
        	$ds_update = "$data[$i]{timet}";
        }

        if ( $data[$i]{rrd_storage_type} eq "MULTIPLE" ) {
            print_log( "DEBUG: MULTIPLE Storage Type", 3 );
            $DS = 1;
            # PNP 0.4.x Template compatibility
            $NAGIOS{RRDFILE} = "";
            
            #
            $rrd_storage_type = "MULTIPLE";
            $rrdfile          = $conf{RRDPATH} . "/" . $data[$i]{hostname} . "/" . $data[$i]{servicedesc} . "_" . $data[$i]{name} . ".rrd";

            # DS is set to 1
            @ds_create = "DS:$DS:$data[$i]{dstype}:$data[$i]{rrd_heartbeat}:$data[$i]{rrd_min}:$data[$i]{rrd_max}";
            $ds_update = "$data[$i]{timet}:$data[$i]{value}";
            @rrd_state = write_rrd();
            @ds_create = ();
            $ds_update = "";
        }
        else {
            print_log( "DEBUG: SINGLE Storage Type", 3 );

            # PNP 0.4.x Template compatibility
            $NAGIOS{RRDFILE} = $conf{RRDPATH} . "/" . $data[0]{hostname} . "/" . $data[0]{servicedesc} . ".rrd";

            #
            $rrd_storage_type = "SINGLE";
            $rrdfile          = $conf{RRDPATH} . "/" . $data[$i]{hostname} . "/" . $data[$i]{servicedesc} . ".rrd";
            push( @ds_create, "DS:$DS:$data[$i]{dstype}:$data[$i]{rrd_heartbeat}:$data[$i]{rrd_min}:$data[$i]{rrd_max}" );
            $ds_update = "$ds_update:$data[$i]{value}";
        }

        write_to_template( "TEMPLATE",         $data[0]{template} );
        write_to_template( "RRDFILE",          $rrdfile );
        write_to_template( "RRD_STORAGE_TYPE", $data[$i]{rrd_storage_type} );
        write_to_template( "RRD_HEARTBEAT",    $data[$i]{rrd_heartbeat} );
        write_to_template( "IS_MULTI",         $data[0]{multi} );
        write_to_template( "DS",               $DS );
        write_to_template( "NAME",             $data[$i]{name} );
        write_to_template( "LABEL",            $data[$i]{label} );
        write_to_template( "UNIT",             $data[$i]{uom} );
        write_to_template( "ACT",              $data[$i]{value} );
        write_to_template( "WARN",             $data[$i]{warning} );
        write_to_template( "WARN_MIN",         $data[$i]{warning_min} );
        write_to_template( "WARN_MAX",         $data[$i]{warning_max} );
        write_to_template( "WARN_RANGE_TYPE",  $data[$i]{warning_range_type} );
        write_to_template( "CRIT",             $data[$i]{critical} );
        write_to_template( "CRIT_MIN",         $data[$i]{critical_min} );
        write_to_template( "CRIT_MAX",         $data[$i]{critical_max} );
        write_to_template( "CRIT_RANGE_TYPE",  $data[$i]{critical_range_type} );
        write_to_template( "MIN",              $data[$i]{min} );
        write_to_template( "MAX",              $data[$i]{max} );

    }

    if ( $rrd_storage_type eq "SINGLE" ) {
        @rrd_state = write_rrd();
    }

    write_state_to_template(@rrd_state);
    write_env_to_template();
    close_template( $NAGIOS{XMLFILE} );
}

sub write_rrd {
    my @rrd_create = ();
    my @rrd_state  = ();

    print_log( "DEBUG: TPL-> $TEMPLATE",  3 );
    print_log( "DEBUG: CRE-> @ds_create", 3 );
    print_log( "DEBUG: UPD-> $ds_update", 3 );

    if ( !-e "$rrdfile" ) {
        @rrd_create = parse_rra_config($TEMPLATE);
        if ( $conf{USE_RRDs} == 1 ) {
            print_log( "RRDs::create $rrdfile @rrd_create @ds_create --start=$NAGIOS{TIMET} --step=$conf{RRA_STEP}", 2 );
            RRDs::create( "$rrdfile", @rrd_create, @ds_create, "--start=$NAGIOS{TIMET}", "--step=$conf{RRA_STEP}" );

            my $err = RRDs::error();
            if ($err) {
            	print_log( "RRDs::create $rrdfile @rrd_create @ds_create --start=$NAGIOS{TIMET} --step=$conf{RRA_STEP}", 0 );
                print_log( "RRDs::create ERROR $err", 0 );
                @rrd_state = ( 1, $err );
                $stats{error}++;
            }
            else {
                print_log( "$rrdfile created", 2 );
                @rrd_state = ( 0, "just created" );
                $stats{create}++;
            }
        }
        else {
            print_log( "RRDs Perl Modules are not installed. Falling back to rrdtool system call.",                           2 );
            print_log( "$conf{RRDTOOL} create $rrdfile @rrd_create @ds_create --start=$NAGIOS{TIMET} --step=$conf{RRA_STEP}", 2 );
            system("$conf{RRDTOOL} create $rrdfile @rrd_create @ds_create --start=$NAGIOS{TIMET} --step=$conf{RRA_STEP}");
            if ( $? > 0 ) {
            	print_log( "$conf{RRDTOOL} create $rrdfile @rrd_create @ds_create --start=$NAGIOS{TIMET} --step=$conf{RRA_STEP}", 0 );
                print_log( "rrdtool create returns $?", 0 );
                @rrd_state = ( $?, "create failed" );
                $stats{error}++;
            }
            else {
                print_log( "rrdtool create returns $?", 1 );
                @rrd_state = ( 0, "just created" );
                $stats{create}++;
            }
        }
    }
    else {
        if ( $conf{USE_RRDs} == 1 ) {
            if ( $conf{RRD_DAEMON_OPTS} ) {
                print_log( "RRDs::update --daemon=$conf{RRD_DAEMON_OPTS} $rrdfile $ds_update", 2 );
                RRDs::update( "--daemon=$conf{RRD_DAEMON_OPTS}", "$rrdfile", "$ds_update" );
            }
            else {
                print_log( "RRDs::update $rrdfile $ds_update", 2 );
                RRDs::update( "$rrdfile", "$ds_update" );
            }
            my $err = RRDs::error();
            if ($err) {
                print_log( "RRDs::update $rrdfile $ds_update", 0 );
                print_log( "RRDs::update ERROR $err", 0 );
                @rrd_state = ( 1, $err );
                $stats{error}++;
            }
            else {
                print_log( "$rrdfile updated", 2 );
                @rrd_state = ( 0, "successful updated" );
                $stats{update}++;
            }
        }
        else {
            print_log( "RRDs Perl Modules are not installed. Falling back to rrdtool system call.", 2 );
            if ( $conf{RRD_DAEMON_OPTS} ) {
                print_log( "$conf{RRDTOOL} update --daemon=$conf{RRD_DAEMON_OPTS} $rrdfile $ds_update", 2 );
                system("$conf{RRDTOOL} update --daemon=$conf{RRD_DAEMON_OPTS} $rrdfile $ds_update");
            }
            else {
                print_log( "$conf{RRDTOOL} update $rrdfile $ds_update", 2 );
                system("$conf{RRDTOOL} update $rrdfile $ds_update");
            }
            if ( $? > 0 ) {
                print_log( "$conf{RRDTOOL} update $rrdfile $ds_update", 0 );
                print_log( "rrdtool update returns $?", 0 );
                @rrd_state = ( $?, "update failed" );
                $stats{error}++;
            }
            else {
                print_log( "rrdtool update returns $?", 1 );
                @rrd_state = ( $?, "successful updated" );
                $stats{update}++;
            }
        }
    }
    return @rrd_state;
}

#
# Write Template
#
sub open_template {
    my $xmlfile = shift;
    $delayed_write = 0;
    if( -e $xmlfile ){
        my $mtime = (stat($xmlfile))[9];
        my $t = time();
        my $age = ($t - $mtime);
        if ( $age < $conf{'XML_UPDATE_DELAY'} ){
            print_log( "DEBUG: XML File is $age seconds old. No update needed", 3 );
            $delayed_write = 1;
            return;
        }
        print_log( "DEBUG: XML File is $age seconds old. UPDATE!", 3 );
    }
    open( XML, "> $xmlfile.$$" ) or die "Cant create temporary XML file ", $!;
    print XML "<?xml version=\"1.0\" encoding=\"" . $conf{XML_ENC} . "\" standalone=\"yes\"?>\n";
    print XML "<NAGIOS>\n";
}

#
# Close Template FH
#
sub close_template {
    return if $delayed_write == 1;
    my $xmlfile = shift;
    printf( XML "  <XML>\n" );
    printf( XML "   <VERSION>%d</VERSION>\n", $const{'XML_STRUCTURE_VERSION'} );
    printf( XML "  </XML>\n" );

    printf( XML "</NAGIOS>\n" );
    close(XML);
    rename( "$xmlfile.$$", "$xmlfile" );
}

#
# Add Lines
#
sub write_to_template {
    return if $delayed_write == 1;
    my $tag  = shift;
    my $data = shift;
    if ( !defined $data ) {
        $data = "";
    }
    if ( $tag =~ /^TEMPLATE$/ ) {
        printf( XML "  <DATASOURCE>\n" );
        printf( XML "    <%s>%s</%s>\n", $tag, "$data", $tag );
    }
    elsif ( $tag =~ /^MAX$/ ) {
        printf( XML "    <%s>%s</%s>\n", $tag, "$data", $tag );
        printf( XML "  </DATASOURCE>\n" );
    }
    else {
        printf( XML "    <%s>%s</%s>\n", $tag, "$data", $tag );
    }
}

sub write_state_to_template {
    return if $delayed_write == 1;
    my @rrd_state = @_;
    printf( XML "  <RRD>\n" );
    printf( XML "    <RC>%s</RC>\n",   $rrd_state[0] );
    printf( XML "    <TXT>%s</TXT>\n", $rrd_state[1] );
    printf( XML "  </RRD>\n" );
}

#
# Store the complete Nagios ENV
#
sub write_env_to_template {
    return if $delayed_write == 1;
    foreach my $key ( sort keys %NAGIOS ) {
        $NAGIOS{$key} = urlencode($NAGIOS{$key});
        printf( XML "  <NAGIOS_%s>%s</NAGIOS_%s>\n", $key, $NAGIOS{$key}, $key );
    }
}

#
# Recursive Template search 
#
sub adjust_template {
    my $command           = shift;
    my $uom               = shift;
    my $count             = shift;
    my @temp_template = split /\!/, $command;
    my $initial_template = cleanup( $temp_template[0] );
    my $template = cleanup( $temp_template[0] );
    my %CTPL = read_custom_template ( $command, $uom, $count );
    # 
    if ( $CTPL{'TEMPLATE'} ne $initial_template ){
        %CTPL = read_custom_template ( $CTPL{'TEMPLATE'}, $uom, $count );
    }
    return %CTPL;
}


#
# Analyse check_command to find PNP Template .
#
sub read_custom_template {
    my $command           = shift;
    my $uom               = shift;
    my $count             = shift;
    my @dstype_list       = ();
    my $use_min_on_create = 0;
    my $use_max_on_create = 0;
    my $rrd_storage_type  = $conf{'RRD_STORAGE_TYPE'};
    my $rrd_heartbeat     = $conf{'RRD_HEARTBEAT'};

    if ( defined($conf{'UOM2TYPE'}{$uom}) ) {
        $dstype = $conf{'UOM2TYPE'}{$uom};
        print_log( "DEBUG: DSTYPE adjusted to $dstype by UOM", 3 );
    }else {
        $dstype = 'GAUGE'; 
    }

    print_log( "DEBUG: RAW Command -> $command", 3 );
    my @temp_template = split /\!/, $command;
    my $template = cleanup( $temp_template[0] );
    $template = trim($template);
    my $template_cfg = "$conf{CFG_DIR}/check_commands/$template.cfg";
    if ( -e $template_cfg ) {
        print_log( "DEBUG: adjust_template() => $template_cfg", 3 );
        my $initial_dstype = $dstype;
        open FH, "<", $template_cfg;
        while (<FH>) {
            next if /^#/;
            next if /^$/;
            s/#.*//;
            s/ //g;
            if (/^(.*)=(.*)$/) {
                if ( $1 eq "DATATYPE" ) {
                    $dstype = uc($2);
                    $dstype =~ s/ //g;
                    @dstype_list = split /,/, $dstype;
                    if ( exists $dstype_list[$count] && $dstype_list[$count] =~ /^(COUNTER|GAUGE|ABSOLUTE|DERIVE)$/ ) {
                        $dstype = $dstype_list[$count];
                        print_log( "Adapting RRD Datatype to \"$dstype\" as defined in $template_cfg with key $count", 2 );
                    }
                    elsif ( $dstype =~ /^(COUNTER|GAUGE|ABSOLUTE|DERIVE)$/ ) {
                        print_log( "Adapting RRD Datatype to \"$dstype\" as defined in $template_cfg", 2 );
                    }
                    else {
                        print_log( "RRD Datatype \"$dstype\" defined in $template_cfg is invalid", 2 );
                        $dstype = $initial_dstype;
                    }

                }
                if ( $1 eq "CUSTOM_TEMPLATE" ) {
                    print_log( "Adapting Template using ARG $2", 2 );
                    my $i = 1;
                    my @keys = split /,/, $2;
                    foreach my $keys (@keys) {
                        if ( $i == 1 && exists $temp_template[$keys] ) {
                            $template = trim( $temp_template[$keys] );
                            print_log( "Adapting Template to $template.php (added ARG$keys)", 2 );
                        }elsif( exists $temp_template[$keys] ){
                            $template .= "_" . trim( $temp_template[$keys] );
                            print_log( "Adapting Template to $template.php (added ARG$keys)", 2 );
                        }
                        $i++;
                    }
                    print_log( "Adapting Template to $template.php as defined in $template_cfg", 2 );
                }
                if ( $1 eq "USE_MIN_ON_CREATE" && $2 eq "1" ) {
                    $use_min_on_create = 1;
                }
                if ( $1 eq "USE_MAX_ON_CREATE" && $2 eq "1" ) {
                    $use_max_on_create = 1;
                }
                if ( $1 eq "RRD_STORAGE_TYPE" && uc($2) eq "MULTIPLE" ) {
                    $rrd_storage_type = uc($2);
                }
                if ( $1 eq "RRD_HEARTBEAT" ) {
                    $rrd_heartbeat = $2;
                }
            }
        }
        close FH;
    }
    else {
        print_log( "No Custom Template found for $template ($template_cfg) ", 2 );
        print_log( "RRD Datatype is $dstype",                                 3 );
    }
    print_log( "Template is $template.php", 2 );
    my %CTPL = (
        TEMPLATE          => $template,
        DSTYPE            => $dstype,
        RRD_STORAGE_TYPE  => $rrd_storage_type,
        RRD_HEARTBEAT     => $rrd_heartbeat,
        USE_MIN_ON_CREATE => $use_min_on_create,
        USE_MAX_ON_CREATE => $use_max_on_create,
    );
    return %CTPL;
}

#
# Parse process_perfdata.cfg
#
sub parse_config {
    my $config_file = shift;
    my $line        = 0;

    if ( -e $config_file ) {
        open CFG, '<', "$config_file";
        while (<CFG>) {
            $line++;
            chomp;
            s/ //g;
            next if /^#/;
            next if /^$/;
            s/#.*//;

            if (/^(.*)=(.*)$/) {
                if ( defined $conf{$1} ) {
                    $conf{$1} = $2;
                }
            }
        }
        close CFG;
        print_log( "Using Config File $config_file parameters", 2 );
    }
    else {
        print_log( "Config File $config_file not found, using defaults", 2 );
    }
}

#
# Parse rra.cfg
#
sub parse_rra_config {
    my $template     = shift;
    my $rra_template = "";
    my @rrd_create = @default_rrd_create;
    if ( -r $conf{'CFG_DIR'} . "/" . $template . ".rra.cfg" ) {
        $rra_template = $conf{'CFG_DIR'} . "/" . $template . ".rra.cfg";
        print_log( "Reading $rra_template", 2 );
    }
    elsif ( -r $conf{'RRA_CFG'} ) {
        $rra_template = $conf{'RRA_CFG'};
        print_log( "Reading $conf{'RRA_CFG'}", 2 );
    }
    else {
        print_log( "No usable rra.cfg found. Using default values.", 2 );
    }

    if ( $rra_template ne "" ) {
        @rrd_create = ();
        open RRA, "<", $rra_template;
        while (<RRA>) {
            next if /^#/;
            next if /^$/;
            s/#.*//;
            if(/^RRA_STEP=(\d+)/i){
                $conf{'RRA_STEP'} = $1;
                next;
            }
            chomp;
            push @rrd_create, "$_";
        }
        close RRA;
    }
    else {
        @rrd_create = @default_rrd_create;
    }
    return @rrd_create;

}

#
# Function adapted from Nagios::Plugin::Performance
# Thanks to Gavin Carr and Ton Voon
#

sub _parse {
    # Nagios::Plugin::Performance
    my $string     = shift;
    my $tmp_string = $string;
    $string =~ s/^([^=]+)=([\d\.\-]+)([\w\/%]*);?([\d\.\-:~@]+)?;?([\d\.\-:~@]+)?;?([\d\.\-]+)?;?([\d\.\-]+)?;?\s*//;

    if ( $tmp_string eq $string ) {
        print_log( "No pattern match in function _parse($string)", 2 );
        return undef;
    }

    return undef unless ( ( defined $1 && $1 ne "" ) && ( defined $2 && $2 ne "" ) );

    # create hash from all performance data values

    my %p = (
        "label"    => $1,
        "name"     => $1,
        "value"    => $2,
        "uom"      => $3,
        "warning"  => $4,
        "critical" => $5,
        "min"      => $6,
        "max"      => $7
    );
    
    $p{label}  =~ s/[']//g;        # cleanup
    $p{name}   =~ s/[']//g;        # cleanup
    $p{name}   =~ s/[\/\\]/_/g;    # cleanup
    $p{name}   = cleanup($p{name});

    if ( $p{uom} eq "%" ) {
        $p{uom} = "%%";
        print_log( "DEBUG: UOM adjust = $p{uom}", 3 );
    }

    #
    # Check for warning and critical ranges
    #
    if ( $p{warning} && $p{warning} =~ /^([\d\.\-~@]+)?:([\d\.\-~@]+)?$/ ) {
        print_log( "DEBUG: Processing warning ranges ( $p{warning} )", 3 );
        $p{warning_min} = $1;
        $p{warning_max} = $2;
        delete( $p{warning} );
        if ( $p{warning_min} =~ /^@/ ) {
            $p{warning_min} =~ s/@//;
            $p{warning_range_type} = "inside";
        }
        else {
            $p{warning_range_type} = "outside";
        }
    }
    if ( $p{critical} && $p{critical} =~ /^([\d\.\-~@]+)?:([\d\.\-~@]+)?$/ ) {
        print_log( "DEBUG: Processing critical ranges ( $p{critical} )", 3 );
        $p{critical_min} = $1;
        $p{critical_max} = $2;
        delete( $p{critical} );
        if ( $p{critical_min} =~ /^@/ ) {
            $p{critical_min} =~ s/@//;
            $p{critical_range_type} = "inside";
        }
        else {
            $p{critical_range_type} = "outside";
        }
    }
    # Strip Range indicators
    $p{warning}  =~ s/[~@]// if($p{warning});
    $p{critical} =~ s/[~@]// if($p{critical});

    return ( $string, %p );
}

#
# clean Strings
#
sub cleanup {
    my $string = shift;
    if ($string) {
        $string =~ s/[ :\/\\]/_/g;
    }
    return $string;
}

#
# Urlencode 
#
sub urlencode {
    my $string = shift;
    if ($string) {
        $string =~ s/([<>&])/sprintf("%%%02x",ord($1))/eg;        # URLencode;
    }
    return $string;
}

#
# Trim leading whitespaces
#
sub trim {
    my $string = shift;
    $string =~ s/^\s*//g;
    return $string;
}

#
# Parse the Performance String and call data2rrd()
#
sub parse_perfstring {

    #
    # Default RRD Datatype
    # Value will be overwritten by adjust_template()
    #
    my %CTPL = ();
    $dstype = "GAUGE";
    my $perfstring = shift;
    my $is_multi = "0";
    my @perfs;
    my @multi;
    my %p;
    my $use_min_on_create = 0;
    my $use_max_on_create = 0;

    #
    # check_multi
    #
    if ( $perfstring =~ /^[']?([a-zA-Z0-9\.\-_\s\/\#]+)::([a-zA-Z0-9\.\-_\s]+)::([^=]+)[']?=/ ) {
        $is_multi = 1;
        print_log( "check_multi Perfdata start", 3 );
        my $count        = 0;
        my $check_multi_blockcount = 0;
        my $multi_parent     = cleanup( $NAGIOS{SERVICEDESC} );
        my $auth_servicedesc = $NAGIOS{DISP_SERVICEDESC};
        while ($perfstring) {
            ( $perfstring, %p ) = _parse($perfstring);
            if ( !$p{label} ) {
                print_log( "Invalid Perfdata detected ", 1 );
                $stats{invalid}++;
                @perfs = ();
                last;
            }
            if ( $p{label} =~ /^[']?([a-zA-Z0-9\.\-_\s\/\#]+)::([a-zA-Z0-9\.\-_\s]+)::([^=]+)[']?$/ ) {
                @multi = ( $1, $2, $3 );
                if ( $count == 0 ) {
                    print_log( "DEBUG: First check_multi block", 3 );

                    # Keep servicedesc while processing the first block.
                    $p{servicedesc}      = cleanup( $NAGIOS{SERVICEDESC} );
                    $p{disp_servicedesc} = $NAGIOS{DISP_SERVICEDESC};
                    $p{auth_servicedesc} = $auth_servicedesc;
                    $p{multi}            = 1;
                    $p{multi_parent}     = $multi_parent;
                }
                else {
                    print_log( "DEBUG: A new check_multi block ($count) starts", 3 );
                    $p{servicedesc}      = cleanup( $multi[0] );    # Use the multi servicedesc.
                    $p{multi}            = 2;
                    $p{multi_parent}     = $multi_parent;
                    $p{servicedesc}      = cleanup( $multi[0] );    # Use the multi servicedesc.
                    $p{disp_servicedesc} = cleanup( $multi[0] );    # Use the multi servicedesc.
                    $p{auth_servicedesc} = $auth_servicedesc;
                    data2rrd(@perfs) if ( $#perfs >= 0 );           # Process when a new block starts.
                    @perfs = ();                                    # Clear the perfs array.
                    # reset check_multi block count
                    $check_multi_blockcount = 0;
                }
                %CTPL = adjust_template( $multi[1], $p{uom}, $check_multi_blockcount++ );

                if ( $CTPL{'USE_MAX_ON_CREATE'} == 1 && defined $p{max} ) {
                    $p{rrd_max} = $p{max};
                } else {
                    $p{rrd_max} = "U";
                }
                if ( $CTPL{'USE_MIN_ON_CREATE'} == 1 && defined $p{min} ) {
                    $p{rrd_min} = $p{min};
                } elsif( $CTPL{'DSTYPE'} eq 'DERIVE' ){
                    $p{rrd_min} = 0; # Add minimum value 0 if DSTYPE = DERIVE
                } else {
                    $p{rrd_min} = "U";
                }
                $p{template}         = $CTPL{'TEMPLATE'};
                $p{dstype}           = $CTPL{'DSTYPE'};
                $p{rrd_storage_type} = $CTPL{'RRD_STORAGE_TYPE'};
                $p{rrd_heartbeat}    = $CTPL{'RRD_HEARTBEAT'};
                $p{label}            = cleanup( $multi[2] );           # store the original label from check_multi header
                $p{name}             = cleanup( $multi[2] );           # store the original label from check_multi header
                $p{hostname}         = cleanup( $NAGIOS{HOSTNAME} );
                $p{disp_hostname}    = $NAGIOS{DISP_HOSTNAME};
                $p{auth_hostname}    = $NAGIOS{HOSTNAME};
                $p{timet}            = $NAGIOS{TIMET};
                push @perfs, {%p};
                $count++;
            }
            else {
                print_log( "DEBUG: Next check_multi data for block $count multiblock $check_multi_blockcount", 3 );

                # additional check_multi data
                %CTPL = adjust_template( $multi[1], $p{uom}, $check_multi_blockcount++ );

                if ( $CTPL{'USE_MAX_ON_CREATE'} == 1 && defined $p{max} ) {
                    $p{rrd_max} = $p{max};
                } else {
                    $p{rrd_max} = "U";
                }

                if ( $CTPL{'USE_MIN_ON_CREATE'} == 1 && defined $p{min} ) {
                    $p{rrd_min} = $p{min};
                } elsif( $CTPL{'DSTYPE'} eq 'DERIVE' ){
                    $p{rrd_min} = 0; # Add minimum value 0 if DSTYPE = DERIVE
                } else {
                    $p{rrd_min} = "U";
                }

                $p{template}         = $CTPL{'TEMPLATE'};
                $p{dstype}           = $CTPL{'DSTYPE'};
                $p{rrd_storage_type} = $CTPL{'RRD_STORAGE_TYPE'};
                $p{rrd_heartbeat}    = $CTPL{'RRD_HEARTBEAT'};
                $p{hostname}         = cleanup( $NAGIOS{HOSTNAME} );
                $p{disp_hostname}    = $NAGIOS{DISP_HOSTNAME};
                $p{auth_hostname}    = $NAGIOS{HOSTNAME};
                $p{timet}            = $NAGIOS{TIMET};
                if ( $count == 1 ) {
                    $p{servicedesc}      = cleanup( $NAGIOS{SERVICEDESC} );    # Use the servicedesc.
                    $p{disp_servicedesc} = $NAGIOS{DISP_SERVICEDESC};          # Use the servicedesc.
                } else {
                    $p{servicedesc}      = cleanup( $multi[0] );               # Use the multi servicedesc.
                    $p{disp_servicedesc} = $multi[0];                          # Use the multi servicedesc.
                }
                $p{multi}        = $is_multi;
                $p{multi_parent} = $multi_parent;
                $p{auth_servicedesc} = $auth_servicedesc;          # Use the servicedesc.
                push @perfs, {%p};
            }
        }
        data2rrd(@perfs) if ( $#perfs >= 0 );
        @perfs = ();
    } else {

        #
        # Normal Performance Data
        #
        print_log( "DEBUG: Normal perfdata", 3 );
        my $count = 0;
        while ($perfstring) {
            ( $perfstring, %p ) = _parse($perfstring);
            if ( !$p{label} ) {
                print_log( "PNP4Nagios: Invalid Perfdata detected ", 1 );
                @perfs = ();
                last;
            }
            %CTPL = adjust_template( $NAGIOS{CHECK_COMMAND}, $p{uom}, $count );

            if ( $CTPL{'USE_MAX_ON_CREATE'} == 1 && defined $p{max} ) {
                $p{rrd_max} = $p{max};
            } else {
                $p{rrd_max} = "U";
            }
            if ( $CTPL{'USE_MIN_ON_CREATE'} == 1 && defined $p{min} ) {
                $p{rrd_min} = $p{min};
            } elsif ( $CTPL{'DSTYPE'} eq 'DERIVE' ){
                $p{rrd_min} = 0; # Add minimum value 0 if DSTYPE = DERIVE
            } else {
                $p{rrd_min} = "U";
            }

            $p{template}         = $CTPL{'TEMPLATE'};
            $p{dstype}           = $CTPL{'DSTYPE'};
            $p{rrd_storage_type} = $CTPL{'RRD_STORAGE_TYPE'};
            $p{rrd_heartbeat}    = $CTPL{'RRD_HEARTBEAT'};
            $p{multi}            = $is_multi;
            $p{hostname}         = cleanup( $NAGIOS{HOSTNAME} );
            $p{disp_hostname}    = $NAGIOS{DISP_HOSTNAME};
            $p{auth_hostname}    = $NAGIOS{DISP_HOSTNAME};
            $p{servicedesc}      = cleanup( $NAGIOS{SERVICEDESC} );
            $p{disp_servicedesc} = $NAGIOS{DISP_SERVICEDESC};
            $p{auth_servicedesc} = $NAGIOS{DISP_SERVICEDESC};
            $p{timet}            = $NAGIOS{TIMET};

            push @perfs, {%p};
            $count++;
        }
        data2rrd(@perfs) if ( $#perfs >= 0 );
        @perfs = ();
    }
}

#
# Write to Logfile
#
sub print_log {
    my $out      = shift;
    my $severity = shift;
    if ( $severity <= $conf{LOG_LEVEL} ) {
        open( LOG, ">>" . $conf{LOG_FILE} ) || die "Can't open logfile ($conf{LOG_FILE}) ", $!;
        if ( -s LOG > $conf{LOG_FILE_MAX_SIZE} ) {
            truncate( LOG, 0 );
            printf( LOG "File truncated" );
        }
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
        printf( LOG "%02d-%02d-%02d %02d:%02d:%02d [%d] [%d] %s\n", $year + 1900, $mon + 1, $mday, $hour, $min, $sec, $$, $severity, $out );
        close(LOG);
    }
}

#
# Signals and Handlers
#
sub init_signals {
    $SIG{'INT'}  = \&handle_signal;
    $SIG{'QUIT'} = \&handle_signal;
    $SIG{'ALRM'} = \&handle_signal;
    $SIG{'ILL'}  = \&handle_signal;
    $SIG{'ABRT'} = \&handle_signal;
    $SIG{'FPE'}  = \&handle_signal;
    $SIG{'SEGV'} = \&handle_signal;
    $SIG{'TERM'} = \&handle_signal;
    $SIG{'BUS'}  = \&handle_signal;
    $SIG{'SYS'}  = \&handle_signal;
    $SIG{'XCPU'} = \&handle_signal;
    $SIG{'XFSZ'} = \&handle_signal;
    $SIG{'IOT'}  = \&handle_signal;
    $SIG{'PIPE'} = \&handle_signal;
    $SIG{'HUP'}  = \&handle_signal;
    $SIG{'CHLD'} = \&handle_signal;
}

#
# Handle Signals
#
sub handle_signal {
    my ($signal) = (@_);
    #
    # Gearman child process
    #
    if ( defined ( $opt_gm ) ){
        if($signal eq "CHLD" && defined($opt_gm) ){
            my $pid = waitpid(-1, &WNOHANG);
            if($pid == -1){
                print_log( "### no hanging child ###", 1 );
            } elsif ( WIFEXITED($?)) {
                print_log( "### child $pid exited ###", 1 );
                $children--;
            } else {
                print_log( "### wrong signal ###", 1 );
                $children--;
            }
            $SIG{'CHLD'} = \&handle_signal;
        }
        if($signal eq "INT" || $signal eq "TERM"){
            local($SIG{CHLD}) = 'IGNORE';   # we're going to kill our children
            kill $signal => keys %children;
            print_log( "*** process_perfdata.pl terminated on signal $signal", 0 );
            pidlock("remove");
            exit;                           # clean up with dignity
        }
        print_log( "*** process_perfdata.pl received signal $signal (ignored)", 0 );
    }else{
        if ( $signal eq "ALRM" ) {
            print_log( "*** TIMEOUT: Timeout after $opt_t secs. ***", 0 );
            if ( $opt_b && !$opt_n ) {
                print_log( "*** TIMEOUT: Deleting current file to avoid loops",   0 );
                print_log( "*** TIMEOUT: Please check your process_perfdata.cfg", 0 );
            }
            elsif ( $opt_b && $opt_n ) {
                print_log( "*** TIMEOUT: Deleting current file to avoid NPCD loops", 0 );
                print_log( "*** TIMEOUT: Please check your process_perfdata.cfg",    0 );
            }
            if ($opt_b) {
                my $pdfile = "$opt_b" . "-PID-" . $$;
                if ( unlink("$pdfile") == 1 ) {
                    print_log( "*** TIMEOUT: $pdfile deleted", 0 );
                }
                else {
                    print_log( "*** TIMEOUT: Could not delete $pdfile:$!", 0 );
                }
            }
            my $temp_file = "$conf{RRDPATH}/$NAGIOS{HOSTNAME}/$NAGIOS{SERVICEDESC}.xml.$$";
            if ( -f $temp_file ) {
                unlink($temp_file);
            }
            $t1 = [gettimeofday];
            $rt = tv_interval $t0, $t1;
            $stats{runtime} = $rt;
            print_log( "*** Timeout while processing Host: \"$NAGIOS{HOSTNAME}\" Service: \"$NAGIOS{SERVICEDESC}\"", 0 );
            print_log( "*** process_perfdata.pl terminated on signal $signal", 0 );
            exit 7;
        }
    }
}


sub init_stats {
    %stats = (
        timet       => time,
        error       => 0,
        invalid     => 0,
        skipped     => 0,
        runtime     => 0,
        rows        => 0,
        create      => 0,
        update      => 0,
    );
}

#
# Store some internal runtime infos
# 
sub store_internals {
    if( ! -w $conf{'STATS_DIR'}){
        print_log("*** ERROR: ".$conf{'STATS_DIR'}." is not writable or does not exist",0);
        return;
    }
    my $statsfile = $conf{'STATS_DIR'}."/".(int $stats{timet} / 60);
    open( STAT, ">> $statsfile" ) or die "Cant create statistic file ", $!;
    printf(STAT "%d %f %d %d %d %d %d %d\n", $stats{timet},$stats{runtime},$stats{rows},$stats{update},$stats{create},$stats{error},$stats{invalid},$stats{skipped}); 
    close(STAT);
    check_internals();
}

#
# Search for statistic files
#
sub check_internals {
    my $file;
    my @files;
    opendir(STATS, $conf{'STATS_DIR'});
    while ( defined ( my $file = readdir STATS) ){
        next if $file =~ /^\.\.?$/; # skip . and ..
        next if $file =~ /-PID-/;   # skip temporary files 
        next if $file == (int $stats{timet} / 60); # skip our current file
        push @files, $file;
    }
    read_internals(@files);
}

#
# Read and aggregate files found by check_internals() 
#
sub read_internals {
    my @files = @_;
    my @chunks;
    foreach my $file (sort { $a <=> $b} @files){
        unless ( rename($conf{'STATS_DIR'}."/".$file, $conf{'STATS_DIR'}."/".$file."-PID-".$$) ){
            print_log( "ERROR: renaming stats file " . $conf{'STATS_DIR'}."/".$file . " to " . $conf{'STATS_DIR'}."/".$file."-PID-".$$ . " failed", 1 );
            next;
        }
        open( STAT, "< ".$conf{'STATS_DIR'}."/".$file."-PID-".$$ );
        %stats = (
            timet       => 0,
            error       => 0,
            invalid     => 0,
            skipped     => 0,
            runtime     => 0,
            rows        => 0,
            create      => 0,
            update      => 0,
        );
        while(<STAT>){
            @chunks = split();
            $stats{timet}    = $chunks[0];
            $stats{runtime} += $chunks[1];
            $stats{rows}    += $chunks[2]; 
            $stats{update}  += $chunks[3];
            $stats{create}  += $chunks[4];
            $stats{error}   += $chunks[5];
            $stats{invalid} += $chunks[6];
            $stats{skipped} += $chunks[7];
        }
        close(STAT);
        unlink($conf{'STATS_DIR'}."/".$file."-PID-".$$);
        process_internals();
    }
}
#
# 
#
sub process_internals {
    my $last_rrd_dtorage_type = $conf{'RRD_STORAGE_TYPE'};
    $conf{'RRD_STORAGE_TYPE'} = "MULTIPLE";
    %NAGIOS = ( 
        HOSTNAME => '.pnp-internal',
        DISP_HOSTNAME => 'pnp-internal',
        SERVICEDESC => 'runtime',
        DISP_SERVICEDESC => 'runtime',
        TIMET => $stats{timet},
        DATATYPE => 'SERVICEPERFDATA',
        CHECK_COMMAND => 'pnp-runtime',
        PERFDATA => "runtime=".$stats{runtime}."s rows=".$stats{rows}." errors=".$stats{error}." invalid=".$stats{invalid}." skipped=".$stats{skipped} ." update=".$stats{update}. " create=".$stats{create} 
    );
    parse_perfstring(  $NAGIOS{PERFDATA} );
    $conf{'RRD_STORAGE_TYPE'} = $last_rrd_dtorage_type;
}

#
# Gearman Worker Daemon
#
sub daemonize {
    if( defined($opt_daemon) ){
        print_log("daemonize init",1);
        chdir '/' or die "Can't chdir to /: $!";
        open STDIN,  '/dev/null'   or die "Can't read /dev/null: $!";
        open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
        open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";
        defined( my $pid = fork )  or die "Can't fork: $!";
        exit if $pid;
        pidlock("create");
        setsid or die "Can't start a new session: $!";
    } else {
        pidlock("create");
    }
    # Fork off our children.
    for (1 .. $conf{'PREFORK'}) {
        new_child();
        print_log( "starting child process $children", 1 );
    }
    while (1) {
        sleep;   # wait for a signal (i.e., child's death)
        for (my $i = $children; $i < $conf{'PREFORK'}; $i++) {
            print_log("starting new child (running = $i)",1);
            new_child();  # top up the child pool
        }
    }
    return;
}

#
# start a new worker process
#
sub new_child {
    my $pid;
    my $sigset;
    my $req = 0;
    # block signal for fork
    $sigset = POSIX::SigSet->new(SIGINT);
    sigprocmask(SIG_BLOCK, $sigset)
        or die "Can't block SIGINT for fork: $!\n";
    
    die "fork: $!" unless defined ($pid = fork);
    
    if ($pid) {
        # Parent records the child's birth and returns.
        sigprocmask(SIG_UNBLOCK, $sigset)
            or die "Can't unblock SIGINT for fork: $!\n";
        $children{$pid} = 1;
        $children++;
        return;
    } else {
        # Child can *not* return from this subroutine.
        $SIG{INT} = 'DEFAULT';      # make SIGINT kill us as it did before
    
        # unblock signals
        sigprocmask(SIG_UNBLOCK, $sigset)
            or die "Can't unblock SIGINT for fork: $!\n";
    
        my $worker = Gearman::Worker->new();
        $worker->job_servers($conf{'GEARMAN_HOST'});
        $worker->register_function("perfdata", 2, sub { return main(@_); });
        my %opt = ( 
                    on_complete => sub { $req++; }, 
                    stop_if => sub { if ( $req > $conf{'REQUESTS_PER_CHILD'} ) { return 1;}; } 
                  );
        print_log("connecting to gearmand '".$conf{'GEARMAN_HOST'}."'",0);
        $worker->work( %opt );
        print_log("max requests per child reached (".$conf{'REQUESTS_PER_CHILD'}.")",1);
        # this exit is VERY important, otherwise the child will become
        # a producer of more and more children, forking yourself into
        # process death.
        exit;
    }
}
#
# Create a pid file
#
sub pidlock {
    return unless defined $opt_pidfile;
    my $action = shift;
    my $PIDFILE = $opt_pidfile;
    if($action eq "create"){
        if ( -e $PIDFILE ) {
            if ( open( OLDPID, "<$PIDFILE" ) ) {
                $_ = <OLDPID>;
                chop($_);
                my $oldpid = $_;
                close(OLDPID);
                if ( -e "/proc/$oldpid/cmdline" ) {
                    print_log("Another instance is already running with PID: $oldpid",0);
                    exit 0;
                } else {
                    print_log("Pidfile $PIDFILE seems to be stale!",0);
                    print_log("Removing old pidfile",0);
                    unlink $PIDFILE;
                }
            }
        }
        if ( !open( PID, ">$PIDFILE" ) ) {
            print_log("Can not create $PIDFILE ( $! )",0);
            exit 1;
        }
        print( PID "$$\n" );
        close(PID);
        print_log("Pidfile ($PIDFILE) created",0);
    }elsif( $action eq "remove" ){
        if ( -e $PIDFILE ) {
            print_log("Removing pidfile ($PIDFILE)",0);
            unlink $PIDFILE;
        }
    }
}

#
# Read crypt key
#
sub read_keyfile {
    my $file = shift;
    my $key = '';
    if( -r $file){
        open(FH, "<", $file);
        while(<FH>){
            chomp(); # avoid \n on last field
            $conf{'KEY'} = $_;
            last;
        }
        close(FH);
        print_log("Using encryption key specified in '$file'",0);
        return 1;
    }else{
        print_log("Using encryption key specified in ".$conf{'CFG_DIR'}."/process_perfdata.cfg",0);
        return 0;
    }
}
#
#
#
sub print_help {
    print <<EOD;

  Copyright (c) 2005-2010 Joerg Linge <pitchfork\@pnp4nagios.org>
  Use process_perfdata.pl to store Nagios Plugin Performance Data into RRD Databases

  Options:
    -h, --help
    Print detailed help screen
    -V, --version
    Print version information
    -t, --timeout=INTEGER
    Seconds before process_perfdata.pl times out (default: $opt_t)
    -i, --inetd
    Use this Option if process_perfdata.pl is executed by inetd/xinetd.
    -d, --datatype
    Defaults to \"SERVICEPERFDATA\". Use \"HOSTPERFDATA\" to process Perfdata from regular Host Checks
    Only used in default or inetd Mode
    -b, --bulk
    Provide a file for bulk update
    -c, --config
    Optional process_perfdata config file
    Default: /srv/app/pnp4nagios/etc/process_perfdata.cfg

  Gearman Worker Options:
    --gearman 
    Start in gearman worker mode
    --daemon
    Run as daemon
    --pidfile=/var/run/process_perfdata.pid
    The pidfile used while running in as gearman worker daemon

EOD
    exit 0;
}

#
#
#
sub print_version {
    print "Version: process_perfdata.pl $const{VERSION}\n";
    print "Copyright (c) 2005-2010 Joerg Linge <pitchfork\@pnp4nagios.org>\n";
    exit 0;
}


#!/usr/bin/perl
# Author: Martin Fuerstenau, Oce Printing Systems
#         martin.fuerstenau_at_oce.com or Martin.fuerstenau_at_maerber.de
#
# Copyright (c) 2011, Martin Fuerstenau <martin.fuerstenau@oce.com>
#
# This module is free software; you can redistribute it and/or modify it
# under the terms of GNU General Public License (GPL) version 3.

#
# Purpose and features of the program:
#
# - check_snmp_brocade is a Nagios plugin to monitor the status of
#   a single fc-port on a Brocade (labeled or original) fibre-channel switch.
#
# History and Changes:
# 
# - 15 Sep 2011 Version 1
#    - First released version. Versions before number 1 were derived from the work
#      of Christian Heim. But now the complete code was rewritten.
#
# - 17 Sep 2011 Version 1.1
#    - Switched from net-snmp-perl to perl-Net-SNMP. Although the coding is
#      a little bit more complex we have the abibility to get complete tables
#      tables with one request which makes getting sensor data (temp, fan, power)
#      more easy.
#    - SNMP version no longer hard coded. Default is 1 but 2c can be handeled over.
#    - If 161 can't be used an alternative port can be given.
#
# - 22 Sep 2011 Version 1.2
#    - Removed subroutine check_port_status because it was only used once. so it
#      doesn't mad sense.
#    - Try to get partner WWN if possible
#
# - 20 Mar 2012 Version 1.3
#    - Added an "offset" for the fc port. In GUI and from the commandline port numbering 
#      starts with 0. SNMP starts with 1. Here we have we hava an offset which can lead
#      to misunderstandings and confusion. Fixed.
#    - Detects Fabric Watch license. If Fabric Watch is enabled we are able to get
#      a lot more information.
#    - Kicked out some subroutines.
#      - snmpget - This was not effective. Before every get a new session was established.
#        Data had to be handled over and passed back. Thee effective code where to lines.
#        It was a nice at a first look but it was more effective to place the code 
#        in the main function
#      - The same for the perfdata. The routine was only used once. So it doesn't make
#        sense to have a subroutine.
#
# - 21 Apr 2012 Version 2.0.0
#    - Bugfix: If a SNMP session can't be established the program exits with an error message.
#      The next line was a session close. this caused un unwanted error message because 
#      there was no session. Fixed.
#    - The program part for getting port data was part of the main code. Moved to a subroutine.
#    - The program part checking for an enabled Fabric Watch license was part of the getting
#      port data code. Moved to a subroutine.
#    - New flag --multiline. Multiline output in overview. This mean technically that
#      a multiline output uses a HTML <br> for the GUI instead of the default (\n). Be aware
#      that your messing connections (email, SMS...) must use a filter to file out the <br>.
#      A sed oneliner like the following will do the job:
#      sed 's/<[^<>]*>//g'
#    - New flag -s|--systeminfo. Get global data like boot date, overall status, reachability etc
#    - New flags --sfptemp, --sfptemp_warn and --allports.
#      Checks the temperature of all SFPs. --sfptemp_warn=INT  will set the warrning offset to the
#      critical temperature as delivered by the system. Default is $SPF_TempHighWarn_def in Celsius.
#      --allports will show all ports. Default is only to show ports which are too hot.--sfptemp_warn
#      and --allports MUST be used with --sfptemp.
#
# - 21 May 2012 Version 2.0.1
#    - New flag --maxsfptemp.
#      Little bugfix. The SFP temperatures delivered by the system may be kinda bullshit. So on 5300
#      min. is reported around -30 degrees celsius and max. is +90 degrees celsius. Because the lower is
#      scrap we have used 0 degrees Celsius as the lowest when designing this plugin. But late we 
#      reckognized that 90 degrees is also too high. flexoptics for example say 0 - 70 degrees. Therefore
#      we changed some things. If $SFP_TempHigh is no set via commandline the temperature from the
#      system will be taken.
#
# - 30 May 2012 Version 2.1.0
#    - First publically available version
#    - New flag --sensor
#      Additional flag to -s. Delivers the values of the onboard sensors for temperature, fans and power.
#
# - 5 Jun 2013 Version 3.2.0
#    - Implemented the changes of Rene Koch, ovido gmbh (r.koch_at_ovido.at)
#      - 26 April 2013 Version 3.0.0
#        - Added support for SNMPv3 (Rene Koch)
#        - Changed exit code to 3 (UNKNOWN) if input validation fails
#    - Not implemented because of a possible misunderstanding. Perhaps later.
#      - 06 May 2013 Version 3.1.0
#        - Added warning and critical checks (Rene Koch)
#    - Changed exit code for failed input validation back to 1. Why? 3 means UNKNOWN. UNKNOWN is a state 
#      returned from the plugin if the plugin receives data (or nothing) from the checked item where it is not 
#      possible to determine a correct error state. But wrong input validation is a minor error. Therefore
#      WARNING is the correct state.
#    - Did some cosmetics. Like many people Rene uses the opening curly brace in the same line as the if statement.
#      I always prefer both curly braces in the same column for better readability.
#    - Cleaned up the code
#    - Replaced tabs with blanks in formatting. Why? Different editors -> different tab stops -> rotten format in editor
#    - Rewritten session establishing section. No need for elsif.


use strict;
use Getopt::Long;

use File::Basename;
use Net::SNMP;



#--- Start presets and declarations -------------------------------------
# 1. Define variables

# General stuff
my $version = '3.1';
my $progname = basename($0);
my $help;                               # If some help is wanted....
my $NoA="";                             # Number of arguments handled over
                                        # the program
my $main_option_counter = 0;            # Needed to check that there is only one 
                                        # main option selected
# Some SNMP stuff
my $result;                             # Points to result hash
my $session;                            # Point to the SNMP session
my $error;                              # If shit happens....
my $oid;                                # To store OID
my $snmpversion;                        # SNMP version
my $snmpversion_def = 1;                # SNMP version default
my $snmpport;                           # SNMP port
my $snmpport_def = "161";               # SNMP port default
my $hostname;                           # Contains the target hostname
my $community;                          # Contains SNMP community of the target hostname

my $snmpv3seclevel;			# SNMPv3 securityLevel
my $snmpv3authproto;			# SNMPv3 auth proto
my $snmpv3privproto;			# SNMPv3 priv proto
my $snmpv3secname;			# SNMPv3 username
my $snmpv3authpassword;			# SNMPv3 authentication password
my $snmpv3privpasswd;			# SNMPv3 privacy password
my $snmpv3context;			# SNMPv3 context name

# For the switch
my $systeminfo;                         # If we wanna get the global system information

my $fc_port;                            # Fibre channel port to monitor - 1st port = 0
my $fc_port_snmp;                       # Fibre channel port to monitor in SNMP  - 1st port = 1
                                        # Port numbering in O and in GUI starts with 0 but SNMP
                                        # uses 1. This can lead to misunderstandings.

my $perf_data;                          # Switch to detect if performance data is desired
my $port_adm_state_key;                 # Port Admin Status
my $port_opr_state_key;                 # Port Operation Status
my $port_phy_state_key;                 # Port Physical Status
my $port_link_state;                    # Port Link Status 1 - enabled, 2 - disabled, 3 - loopback
my $partner_wwn;                        # Needed to detect the partner
my @partner_wwn;                        # Needed to detect the partner
my $FabricWatchLicense;                 # Fabric Watch licensed? 1 = licensed, 2 0 not licensed

# for the output of performance data we need the following stats:
my $swFCPortTxWords;                    # stat_wtx (words out)
my $swFCPortRxWords;                    # stat_wrx (words in)
my $swFCPortTxFrames;                   # stat_ftx (frames out)
my $swFCPortRxFrames;                   # stat_wtx (frames in)
my $swFCPortRxEncInFrs;                 # er_enc_in (encoding err)
my $swFCPortRxCrcs;                     # er_crc
my $swFCPortRxTruncs;                   # er_trunc
my $swFCPortRxTooLongs;                 # er_toolong
my $swFCPortRxBadEofs;                  # er_bad_eof
my $swFCPortRxEncOutFrs;                # er_enc_eof
my $swFCPortC3Discards;                 # er_c3_timeout

my $r_code = 0;                         # Exitcode for get_out
my $r_message;                          # Message for get_out
my $tmp_message = "";			# Temp message for get_out
my $multiline;                          # Multiline output in overview. This mean technically that
                                        # a multiline output uses a HTML <br> for the GUI instead of
                                        # Be aware that your messing connections (email, SMS...) must use
                                        # a filter to file out the <br>. A sed oneliner like the following
                                        # will do the job:
                                        # sed 's/<[^<>]*>//g'
my $multiline_def="\n";                 # Default for $multiline;
my $global;                             # Global data like boot date, overall status etc.

my $sfp_temp;                           # SFP transceiver temperature

my $SFP_TempHigh;                       # Transceiver port high temperature. This is the critical limit.    
                                        # Transceiver port high temperature from the system.
                                        # This is the default critical limit. If $SFP_TempHigh is set by the commandline
                                        # it will replace the value deliverd by the system.

my $SFP_TempHighWarn;                   # Transceiver port high temperature warning. This is an offset to 
                                        # $SFP_TempHigh.
my $SFP_TempHighWarn_def = 10;          # This is the default offset for $SPF_TempHighWarn

my $allports;                           # Default is only to show ports which are too hot. With this flag all
                                        # ports will be shown.
my $sensorinfo;                           # 

# 2. Define arrays and hashes  

# Assign some strings in a hash. It makes it more comfortable to convert numeric values to strings
my %port_adm_state = (
                      "1" => "online",
                      "2" => "offline",
                      "3" => "testing",
                      "4" => "faulty"
                      ); 

my %port_opr_state = (
                      "0" => "unknown",
                      "1" => "online",
                      "2" => "offline",
                      "3" => "testing",
                      "4" => "faulty"
                      ); 

my %port_phy_state = (
                      "1" => "noCard",
                      "2" => "noTransceiver",
                      "3" => "LaserFault",
                      "4" => "noLight",
                      "5" => "noSync",
                      "6" => "inSync",
                      "7" => "portFault",
                      "8" => "diagFault",
                      "9" => "lockRef"
                      ); 


#--- End presets --------------------------------------------------------

# First we have to fix  the number of arguments

$NoA=$#ARGV;

Getopt::Long::Configure('bundling');
GetOptions
	("H=s" => \$hostname,            "hostname=s"       => \$hostname,
         "C=s" => \$community,           "community=s"      => \$community,
	 "s"   => \$systeminfo,          "systeminfo"       => \$systeminfo,
	                                 "sensor"           => \$sensorinfo,
	                                 "sfptemp"          => \$sfp_temp,
	                                 "sfptemp_warn=i"   => \$SFP_TempHighWarn,
	                                 "allports"         => \$allports,
	 "P=i" => \$fc_port,             "fcport=i"         => \$fc_port,
	 "p"   => \$perf_data,           "performancedata"  => \$perf_data,
	 "v=s" => \$snmpversion,         "snmpversion=s"    => \$snmpversion,
	                                 "port=s"           => \$snmpport,
         "L=s" => \$snmpv3seclevel,      "seclevel=s"       => \$snmpv3seclevel,
         "a=s" => \$snmpv3authproto,     "authproto=s"      => \$snmpv3authproto,
         "x=s" => \$snmpv3privproto,     "privproto=s"      => \$snmpv3privproto,
         "U=s" => \$snmpv3secname,       "secname=s"        => \$snmpv3secname,
         "A=s" => \$snmpv3authpassword,  "authpassword=s"   => \$snmpv3authpassword,
         "X=s" => \$snmpv3privpasswd,    "privpasswd=s"     => \$snmpv3privpasswd,
         "n=s" => \$snmpv3context,       "context=s"        => \$snmpv3context,
	                                 "multiline"        => \$multiline,
	                                 "maxsfptemp=s"     => \$SFP_TempHigh,
         "h"   => \$help,                "help"             => \$help);

# Several checks to check parameters
if ($help)
   {
   help();
   exit 0;
   }

# Multiline output in GUI overview?
if ($multiline)
   {
   $multiline = "<br>";
   }
else
   {
   $multiline = $multiline_def;
   }

# Right number of arguments (therefore NoA :-)) )

if ( $NoA == -1 )
   {
   usage();
   exit 1;
   }


if (!$hostname)
   {
   print "Host name/address not specified\n\n";
   usage();
   exit 1;
   }

if (!$community && !$snmpv3secname)
   {
   $community = "public";
   print "No community string supplied - using public\n";
   }

# Here we add the offset of 1 to the given port to have the appropriate value for SNMP
# You can not test for the variable like if ($fc_port) because a value of 0 also means undefined

if (length $fc_port)
   {
   $fc_port_snmp = $fc_port + 1;
   }

# One valid category must be selected
if (!$systeminfo && !$fc_port_snmp && !$sfp_temp)
   {
   print "\nYou must select systeminfo or sfptemp or a port!\n\n";
   usage();
   exit 1;
   }

if (!$snmpversion)
   {
   $snmpversion = $snmpversion_def;
   }

if ($snmpversion ne "1" && $snmpversion ne "2c" && $snmpversion ne "3")
   {
   print "SNMP version ($snmpversion) entered is neither 1, 2c nor 3. Only these are supported versions\n\n";
   usage();
   exit 1;
   }

# SNMPv3 checks
if ($snmpversion eq "3")
   {
   # securityLevel
   if (! $snmpv3seclevel)
      {
      $snmpv3seclevel = "noAuthNoPriv";
      }

   # username
   if (! $snmpv3secname)
      {
      print "SNMP version 3 requires an username!\n\n";
      usage();
      exit 1;
      }

   if ($snmpv3seclevel ne "noAuthNoPriv" && $snmpv3seclevel ne "authNoPriv" && $snmpv3seclevel ne "authPriv")
      {
      print "SNMP version 3 security level ($snmpv3seclevel) invalid!\n\n";
      usage();
      exit 1;
      }

   if ($snmpv3seclevel eq "authNoPriv" || $snmpv3seclevel eq "authPriv")
      {
      # authproto
      if (! $snmpv3authproto)
         {
         $snmpv3authproto = "md5";
         }
      else
         {
         $snmpv3authproto = lc($snmpv3authproto);
         }

      if ($snmpv3authproto ne "md5" && $snmpv3authproto ne "sha")
         {
         print "SNMP version 3 auth proto ($snmpv3authproto) invalid!\n\n";
         usage();
         exit 1;
         }

      # auth password
      if (! $snmpv3authpassword)
         {
         print "SNMP version 3 $snmpv3seclevel requires auth password!\n\n";
         usage();
         exit 1;
         }
      }

   if ($snmpv3seclevel eq "authPriv")
      {
      # privproto
      if (! $snmpv3privproto)
         {
         $snmpv3privproto = "3des";
         }
      else
         {
         $snmpv3privproto = lc($snmpv3privproto);
         }

      if ($snmpv3privproto ne "3des" && $snmpv3privproto ne "aes")
         {
         print "SNMP version 3 priv proto ($snmpv3privproto) invalid!\n\n";
         usage();
         exit 1;
         }

      # priv password
      if (! $snmpv3privpasswd)
         {
         print "SNMP version 3 $snmpv3seclevel requires priv password!\n\n";
         usage();
         exit 1;
         }
      }
   }

if (!$snmpport)
   {
   $snmpport = $snmpport_def;
   }

if ($fc_port_snmp)
   {
   $main_option_counter++;
   }

if ($systeminfo)
   {
   $main_option_counter++;
   }

if ($sfp_temp)
   {
   $main_option_counter++;
   }

if ($main_option_counter > 1)
   {
   print "You have to select either a port to check OR the systeminfo (global info, fan, powersupply etc.) NOT both!\n\n";
   usage();
   exit 1;
   }

#
# So here starts the main section.------------------------------------------------------------------
#

# First open a session
if ($snmpversion eq "3")
   {
   if ($snmpv3seclevel eq "noAuthNoPriv")
      {
      ($session, $error) = Net::SNMP->session( -hostname  => $hostname,
                                               -version   => $snmpversion,
                                               -port      => $snmpport,
                                               -retries   => 10,
                                               -timeout   => 10,
                                               -username  => $snmpv3secname
                                              );
      }
   if ($snmpv3seclevel eq "authNoPriv")
      {
      ($session, $error) = Net::SNMP->session( -hostname  => $hostname,
					 -version   => $snmpversion,
					 -port      => $snmpport,
					 -retries   => 10,
					 -timeout   => 10,
					 -username  => $snmpv3secname,
					 -authprotocol => $snmpv3authproto,
					 -authpassword => $snmpv3authpassword
					);
      }
   if ($snmpv3seclevel eq "authPriv")
      {
      ($session, $error) = Net::SNMP->session( -hostname  => $hostname,
                                               -version   => $snmpversion,
                                               -port      => $snmpport,
                                               -retries   => 10,
                                               -timeout   => 10,
                                               -username  => $snmpv3secname,
                                               -authprotocol => $snmpv3authproto,
                                               -authpassword => $snmpv3authpassword,
                                               -privprotocol => $snmpv3privproto,
                                               -privpassword => $snmpv3privpasswd
                                              );
      }

   }
else
   {
   ($session, $error) = Net::SNMP->session( -hostname  => $hostname,
                                            -version   => $snmpversion,
                                            -community => $community,
                                            -port      => $snmpport,
                                            -retries   => 10,
                                            -timeout   => 10
                                           );
   }


# If there is something wrong...exit

if (!defined($session))
   {
   printf("ERROR: %s.\n", $error);
   print "Exiting\n";
   exit 1;
   }

# If we wanna get the system status here is the starting point
if ($systeminfo)
   {
   get_system_info();

   # If we wanna get sensors like fan, power and onboard temperature
   # here is the starting point

   if ($sensorinfo)
      {
      get_sensor_info();
      }
   }
   
# If we wanna get port data here is the starting point

if ($fc_port_snmp)
   {
   get_port_data();
   }

# If we wanna get SFP temperature here is the starting point

if ($sfp_temp)
   {
   get_sfp_temp();
   }


# And now we leave
get_out($r_code, "$r_message");

# ---- Subroutines -------------------------------------------------------

sub get_result()
    {
    my $tmp_result = undef;

    # handle snmp v3 context name

    if ($snmpv3context)
       {
       $tmp_result = $session->get_request( -contextname => $snmpv3context, -varbindlist => ["$oid"] );
       }
    else
       {
       $tmp_result = $session->get_request( -varbindlist => ["$oid"] );
       }
    return $tmp_result;
    }

sub get_table()
    {
    my $tmp_result = undef;

    # handle snmp v3 context name

    if ($snmpv3context)
       {
       $tmp_result = $session->get_table( -contextname => $snmpv3context, -baseoid => $oid );
       }
    else
       {
       $tmp_result = $session->get_table( -baseoid => $oid );
       }
    return $tmp_result;
    }

sub get_request()
    {
    my $tmp_result = undef;

    # handle snmp v3 context name

    if ($snmpv3context)
       {
       $tmp_result = $session->get_request( -contextname => $snmpv3context, -varbindlist => ["$oid"] );
       }
    else
       {
       $tmp_result = $session->get_request( -varbindlist => ["$oid"] );
       }
    return $tmp_result;
    }

sub get_system_info()
    {
    # Global status data
    my $tmp_r_message;
    my $tmp_r_code;
       
    # Boot date
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.1.2.0";
    $result = get_result();

    if ($session->error_status() == 0)
       {
       $tmp_r_message = $$result{$oid};
       chomp $tmp_r_message;
       $r_message = "Boot date: $tmp_r_message$multiline";
       }
    else
       {
       $r_message = "Boot date: Not supported$multiline";
       }
       

    # Firmware version
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.1.6.0";
    $result = get_result();

    if ($session->error_status() == 0)
       {
       $tmp_r_message = $$result{$oid};
       chomp $tmp_r_message;
       $r_message = $r_message . "Firmware version: $tmp_r_message$multiline";
       }
    else
       {
       $r_message = "Firmware version: Not supported$multiline";
       }

       
    # Model
    $oid = ".1.3.6.1.2.1.47.1.1.1.1.2.1";
    $result = get_result();

    if ($session->error_status() == 0)
       {
       $tmp_r_message = $$result{$oid};
       chomp $tmp_r_message;
       $r_message = $r_message . "Model: $tmp_r_message$multiline";
       }
    else
       {
       $r_message = "Model: Not supported$multiline";
       }

       
    # Serialnumber
    $oid = ".1.3.6.1.2.1.47.1.1.1.1.11.1";
    $result = get_result();

    if ($session->error_status() == 0)
       {
       $tmp_r_message = $$result{$oid};
       chomp $tmp_r_message;
       $r_message = $r_message . "Serialnumber: $tmp_r_message$multiline";
       }
    else
       {
       $r_message = "Serialnumber: Not supported$multiline";
       }
       
      
    # Operational Status
    # The current operational status of the switch.
    # The states are as follow:
    # 1 - online means the switch is accessible by an external Fibre Channel port
    # 2 - offline means the switch is not accessible
    # 3 - testing means the switch is in a built-in test mode and is not accessible
    #     by an external Fibre Channel port
    # 4- faulty means the switch is not operational.
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.1.7.0";
    $result = get_result();

    if ($session->error_status() == 0)
       {
       $tmp_r_code = $$result{$oid};
       chomp $tmp_r_code;

       if ($tmp_r_code == 1)
          {
          $r_message = $r_message . "Operational Status: Online and accessible$multiline";
          }
       if ($tmp_r_code == 2)
          {
          $r_code = 2;
          $r_message = $r_message . "Operational Status: ERROR! Offline not accessible$multiline";
          }
       if ($tmp_r_code == 3)
          {
          $r_code = 1;
          $r_message = $r_message . "Operational Status: Warning! Testing mode not accessible$multiline";
          }
       if ($tmp_r_code == 4)
          {
          $r_code = 2;
          $r_message = $r_message . "Operational Status: ERROR! Faulty not accessible$multiline";
          }
       }
    else
       {
       $r_message = "Operational Status: Not supported$multiline";
       }
    }

sub get_sensor_info()
    {
    my $key;
    my $SensorField;
    my $SensorIndex;
    my %Sensor2Index;
    my $SensorType;
    my %SensorType2Index;
    my $SensorValue;
    my $SensorStatus;
    my $SensorInfo;
    my $tmp_perf_data;
    

    # SENSOR_TYPE   = .1.3.6.1.4.1.1588.2.1.1.1.1.22.1.2
    # SENSOR_STATUS = .1.3.6.1.4.1.1588.2.1.1.1.1.22.1.3
    # SENSOR_VALUE  = .1.3.6.1.4.1.1588.2.1.1.1.1.22.1.4
    # SENSOR_INFO   = .1.3.6.1.4.1.1588.2.1.1.1.1.22.1.5

    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.1.22.1";
    $result = get_table();

    if ($session->error_status() == 0)
       {
       # The elements are unsorted. And we do not need the OID as key
       # We need the index number which is the last digit of the OID
       # So we build 2 new hashes:
       # %SensorType2Index contains the mapping  for index numbers and sensortypes
       # %Sensor2Index contains the mapping  for status, value and info
       
       foreach $key ( keys %$result)
               {
               $SensorField = $$result{$key};
               $SensorIndex = $key;
               $SensorIndex =~ s/\.1.3\.6\.1\.4\.1\.1588\.2\.1\.1\.1\.1\.22\.1\.//;

               if ($SensorIndex !~ m/^1\..*$/ )
                  {
                  if ($SensorIndex =~ m/^2\..*$/ )
                     {
                     $SensorIndex =~ s/^2\.//;
                     $SensorType2Index{$SensorIndex} = $SensorField;
                     }
                  else
                     {
                     $Sensor2Index{$SensorIndex} = $SensorField;
                     }
                  }
                  
               }

       # Sensor table. Sensor types
       # 1 - temperature (in degrees celsius)
       # 2 - fan
       # 3 - power-supply


       foreach $key ( sort { $a <=> $b } (keys %SensorType2Index))
               {
               # The current status of the sensor.
               # Enumerations:
               # 1 - unknown
               # 2 - faulty
               # 3 - below-min
               # 4 - nominal
               # 5 - above-max
               # 6 - absent

               if ($SensorType2Index{$key} == 1)
                  {
                  $SensorIndex = "3.$key";
                  $SensorStatus = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "4.$key";
                  $SensorValue = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "5.$key";
                  $SensorInfo = $Sensor2Index{$SensorIndex};
                  $SensorInfo =~ s/#//g;
                  $SensorInfo =~ s/ /-/g;
                  $SensorInfo =~ s/:-/\//g;

                  if ($SensorStatus == 1)
                     {
                     $r_message =  $r_message . "$SensorInfo: Unknown status$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }

                  if ($SensorStatus == 2)
                     {
                     $r_message =  $r_message . "$SensorInfo: Faulty$multiline";
                     if ($r_code < 2)
                        {
                        $r_code = 2;
                        }
                     }

                  if (($SensorStatus == 3) || ($SensorStatus == 4) || ($SensorStatus == 5))
                     {
                     if ($SensorStatus == 3)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue Degree Celsius is below-min$multiline";
                        if ($r_code < 2)
                           {
                           $r_code = 2;
                           }
                        }

                     if ($SensorStatus == 4)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue Degree Celsius$multiline";
                        }

                     if ($SensorStatus == 5)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue Degree Celsius is above-max$multiline";
                        if ($r_code < 2)
                           {
                           $r_code = 2;
                           }
                        }
                     # Build the perfdata string
                     if ( $perf_data )
                        {
                        if ( $perf_data == 1 )
                           {
                           $perf_data = "$SensorInfo=$SensorValue;;;";
                           }
                        else
                           {
                           $perf_data = $perf_data . "$SensorInfo=$SensorValue;;;";
                           }
                        }
                     }

                  if ($SensorStatus == 6)
                     {
                     $r_message =  $r_message . "$SensorInfo: Sensor absent$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }
                  }

               if ($SensorType2Index{$key} == 2)
                  {
                  $SensorIndex = "3.$key";
                  $SensorStatus = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "4.$key";
                  $SensorValue = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "5.$key";
                  $SensorInfo = $Sensor2Index{$SensorIndex};
                  $SensorInfo =~ s/ //g;
                  $SensorInfo =~ s/#/-/g;

                  if ($SensorStatus == 1)
                     {
                     $r_message =  $r_message . "$SensorInfo: Unknown status$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }

                  if ($SensorStatus == 2)
                     {
                     $r_message =  $r_message . "$SensorInfo: Faulty$multiline";
                     if ($r_code < 2)
                        {
                        $r_code = 2;
                        }
                     }

                  if (($SensorStatus == 3) || ($SensorStatus == 4) || ($SensorStatus == 5))
                     {
                     if ($SensorStatus == 3)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue RPM is below-min$multiline";
                        if ($r_code < 2)
                           {
                           $r_code = 2;
                           }
                        }

                     if ($SensorStatus == 4)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue RPM$multiline";
                        }

                     if ($SensorStatus == 5)
                        {
                        $r_message =  $r_message . "$SensorInfo: $SensorValue RPM is above-max$multiline";
                        if ($r_code < 2)
                           {
                           $r_code = 2;
                           }
                        }
                     # Build the perfdata string
                     if ( $perf_data )
                        {
                        if ( $perf_data == 1 )
                           {
                           $perf_data = "$SensorInfo=$SensorValue;;;";
                           }
                        else
                           {
                           $perf_data = $perf_data . "$SensorInfo=$SensorValue;;;";
                           }
                        }
                      }

                  if ($SensorStatus == 6)
                     {
                     $r_message =  $r_message . "$SensorInfo: Sensor absent$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }
                  }

               if ($SensorType2Index{$key} == 3)
                  {
                  $SensorIndex = "3.$key";
                  $SensorStatus = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "4.$key";
                  $SensorValue = $Sensor2Index{$SensorIndex};
                  
                  $SensorIndex = "5.$key";
                  $SensorInfo = $Sensor2Index{$SensorIndex};
                  $SensorInfo =~ s/ //g;
                  $SensorInfo =~ s/#/-/g;

                  if ($SensorStatus == 1)
                     {
                     $r_message =  $r_message . "$SensorInfo: Unknown status$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }

                  if ($SensorStatus == 2)
                     {
                     $r_message =  $r_message . "$SensorInfo: Faulty$multiline";
                     if ($r_code < 2)
                        {
                        $r_code = 2;
                        }
                     }

                  if ($SensorStatus == 3)
                     {
                     $r_message =  $r_message . "$SensorInfo: below-min$multiline";
                     if ($r_code < 2)
                        {
                        $r_code = 2;
                        }
                     }

                  if ($SensorStatus == 4)
                     {
                     $r_message =  $r_message . "$SensorInfo: OK$multiline";
                     }

                  if ($SensorStatus == 5)
                     {
                     $r_message =  $r_message . "$SensorInfo: above-max$multiline";
                     if ($r_code < 2)
                        {
                        $r_code = 2;
                        }
                     }

                  if ($SensorStatus == 6)
                     {
                     $r_message =  $r_message . "$SensorInfo: Sensor absent$multiline";
                     if ($r_code < 1)
                        {
                        $r_code = 1;
                        }
                     }
                  }
               }
       if ( $perf_data )
          {
          $r_message = $r_message . "|" . $perf_data;
          }
       }
    else
       {
       $r_message =  $r_message . "Sensor table: Not supported$multiline";
       }
    
    
    }

sub get_sfp_temp()
    {
    my $key;
    my $TransTemp;
    my $port;
    my %port2temp;
    my $firstrun = 1;
    my $FailedPort;
    
    # Fabric Watch licensed?
    # 1 - swFwLicensed
    # 2 - swFwNotLicensed
    $FabricWatchLicense=FW_Lic();

    if ($FabricWatchLicense == 2)
       {
       print "No Fabric Watch license enabled. SFP temperature monitoring needs an enabled FW license.\n";
       exit 1;
       }

    # If it is not handled over via commandline get it from the system
    if (!$SFP_TempHigh)
       {
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.10.2.1.6.4";
       $result = get_request();
       $SFP_TempHigh = $$result{$oid};
       }

    # Now we calculate the warning temperature
    if (!$SFP_TempHighWarn)
       {
       $SFP_TempHighWarn = $SFP_TempHigh - $SFP_TempHighWarn_def;
       }
    else
       {
       $SFP_TempHighWarn = $SFP_TempHigh - $SFP_TempHighWarn;
       }
   
   
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.10.3.1.5.4";
    $result = get_table();

    # The elements are unsorted. And we do not need the OID as key
    # We need the port number which is the last digit of the OID
    # So we build a new hash %port2temp
    foreach $key ( keys %$result)
            {
            $TransTemp = $$result{$key};
            $port = $key;
            $port =~ s/\.1.3\.6\.1\.4\.1\.1588\.2\.1\.1\.1\.10\.3\.1\.5\.4\.//;

            # Here again we have the offset as with port monitoring. The GUI and the
            # CLI of Brocade starts with port 0. SNMP starts numbering with port 1.
            # this can be confusing.
            $port = $port - 1;

            $port2temp{$port} = $TransTemp;
            }

    foreach $key ( sort { $a <=> $b } (keys %port2temp))
            {
            # Show all ports?
            if ( $allports )
               {
               if ( $firstrun == 1 )
                  {
                  $firstrun = 0;
                  $r_message = "Port: $key Temp: $port2temp{$key} Celsius$multiline";
                  }
               else
                  {
                  $r_message = $r_message . "Port: $key Temp: $port2temp{$key} Celsius$multiline";
                  }
               } 
            # Build the perfdata string
            if ( $perf_data )
               {
               if ( $perf_data == 1 )
                  {
                  $perf_data = "Port-$key=$port2temp{$key};$SFP_TempHighWarn;$SFP_TempHigh;";
                  }
               else
                  {
                  $perf_data = $perf_data . "Port-$key=$port2temp{$key};$SFP_TempHighWarn;$SFP_TempHigh;";
                  }
               }
            
            if ( $port2temp{$key} >= $SFP_TempHighWarn  && $port2temp{$key} <= $SFP_TempHigh)
               {
               if ($r_code < 1 )
                  {
                  $r_code = 1;
                  }
               $FailedPort = "$FailedPort $port2temp{$key}";
               }

            if ( $port2temp{$key} >= $SFP_TempHigh)
               {
               if ($r_code < 2 )
                  {
                  $r_code = 2;
                  }
               $FailedPort = "$FailedPort $port2temp{$key}";
               }
            }
    if ( $perf_data )
       {
       $r_message = $r_message . "|" . $perf_data;
       }
    if ( $r_code == 0 )
       {
       $r_message = "Every temperature on every port is ok$multiline" . $r_message;
       }
    if ( $r_code == 1 )
       {
       $r_message = "Warning! Temperature on port(s) $FailedPort is too high$multiline" . $r_message;
       }
    if ( $r_code == 2 )
       {
       $r_message = "Critical! Temperature on port(s) $FailedPort is too high$multiline" . $r_message;
       }
    }


sub get_port_data()
    {
    # Fabric Watch licensed?
    # 1 - swFwLicensed
    # 2 - swFwNotLicensed
    $FabricWatchLicense=FW_Lic();

    # check the operational port status
    # result values from the switch:
    # 0: unknown,    1: online,   2: offline
    # 3: testing,    4: faulty
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.4.$fc_port_snmp";
    $result = get_request();
    $port_opr_state_key = $$result{$oid};

    # check the physical port status
    # result values from the switch:
    # 1: noCard,      2: noTransceiver, 3: LaserFault
    # 4: noLight,     5: noSync,        6: inSync,
    # 7: portFault,   8: diagFault,     9: lockRef
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.3.$fc_port_snmp";
    $result = get_request();
    $port_phy_state_key = $$result{$oid};


    # check the link port state
    # result values from the switch:
    # 1: enabled   - port is allowed to participate in the FC-PH protocol with its
    #                attached port (or ports if it is in a FC-AL loop)
    # 2: disabled  - the port is not allowed to participate in the FC-PH protocol
    #                with its attached port(s)
    # 3: loopback  - the port may transmit frames through an internal path to verify
    #                the health of the transmitter and receiver path

    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.6.$fc_port_snmp";
    $result = get_request();
    $port_link_state = $$result{$oid};


    # And now we try to get the partner WWN (thats pretty cool I think)
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.7.2.1.6.$fc_port_snmp";
    $result = get_request();
    $partner_wwn = $$result{$oid};

    # Now we have the WWN but formatted as (for example) 20000000c9471f3b
    # but we want 20:00:00:00:c9:47:1f:3b. So the following is a not elegant
    # but it works. A sophisticated regular exporession would be better
   
    $partner_wwn  =~ s/^0x//;
    @partner_wwn = split(//, $partner_wwn );

    $partner_wwn = "$partner_wwn[0]$partner_wwn[1]:";
    $partner_wwn = "$partner_wwn$partner_wwn[2]$partner_wwn[3]:";
    $partner_wwn = "$partner_wwn$partner_wwn[4]$partner_wwn[5]:";
    $partner_wwn = "$partner_wwn$partner_wwn[6]$partner_wwn[7]:";
    $partner_wwn = "$partner_wwn$partner_wwn[8]$partner_wwn[9]:";
    $partner_wwn = "$partner_wwn$partner_wwn[10]$partner_wwn[11]:";
    $partner_wwn = "$partner_wwn$partner_wwn[12]$partner_wwn[13]:";
    $partner_wwn = "$partner_wwn$partner_wwn[14]$partner_wwn[15]";

    if ( $perf_data )
       {
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.11.$fc_port_snmp";
       $result = get_request();
       $swFCPortTxWords = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.12.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxWords = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.13.$fc_port_snmp";
       $result = get_request();
       $swFCPortTxFrames = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.14.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxFrames = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.21.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxEncInFrs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.22.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxCrcs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.23.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxTruncs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.24.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxTooLongs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.25.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxBadEofs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.26.$fc_port_snmp";
       $result = get_request();
       $swFCPortRxEncOutFrs = $$result{$oid};
      
       $oid = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1.28.$fc_port_snmp";
       $result = get_request();
       $swFCPortC3Discards = $$result{$oid};
      
       $perf_data = "stat_wtx=$swFCPortTxWords;0;0;0;0";
       $perf_data .= " stat_wrx=$swFCPortRxWords;0;0;0;0";
       $perf_data .= " stat_ftx=$swFCPortTxFrames;0;0;0;0";
       $perf_data .= " stat_frx=$swFCPortRxFrames;0;0;0;0";
       $perf_data .= " er_enc_in=$swFCPortRxEncInFrs;0;0;0;0";
       $perf_data .= " er_crc=$swFCPortRxCrcs;0;0;0;0";
       $perf_data .= " er_trunc=$swFCPortRxTruncs;0;0;0;0";
       $perf_data .= " er_toolong=$swFCPortRxTooLongs;0;0;0;0";
       $perf_data .= " er_bad_eof=$swFCPortRxBadEofs;0;0;0;0";
       $perf_data .= " er_enc_out=$swFCPortRxEncOutFrs;0;0;0;0";
       $perf_data .= " er_c3_timeout=$swFCPortC3Discards;0;0;0;0";
       }
    else
       {
       $perf_data = "";
       }

    # Check the port only if it configured 'UP'
    if ( defined $port_opr_state_key )
       {
       if ( $port_opr_state_key == 0 )
          {
          if ( $port_link_state == 1 )
             {
             $r_code = 2;
             $r_message = "FC port $fc_port swFCPortPhyState is $port_phy_state{$port_phy_state_key} and NOT disabled. Please disable port.";
             }
          if ( $port_link_state == 2 )
             {
             $r_code = 0;
             $r_message = "FC port $fc_port swFCPortPhyState is $port_phy_state{$port_phy_state_key}";
             }
          }

       if ( $port_opr_state_key == 1 )
          {
          # If the ports operational status isn't 'UP', check further.
          if ( $port_opr_state_key != 1 )
             {
 
             # Check the physical interface status too
             # makes diagnosing troubles a bit easier.
 
             $r_code = 2;
             $r_message = "Port $fc_port swFCPortPhyState is $port_phy_state{$port_phy_state_key}";
             }

          if ( $port_opr_state_key == 1 && $port_phy_state_key == 6 )
             {
              if ($partner_wwn eq ":::::::" )
                 {
                 $r_code = 0;
                 $r_message ="FC port $fc_port swFCPortPhyState is $port_phy_state{$port_phy_state_key}. Partner unknown. $tmp_message|$perf_data";
                 }
              else
                 {
                 $r_code = 0;
                 $r_message = "FC port $fc_port swFCPortPhyState is $port_phy_state{$port_phy_state_key}. Partner is $partner_wwn. $tmp_message|$perf_data";
                 }
             }
          }

       if ( $port_opr_state_key == 2 )
          {
          if ( $port_link_state == 1 )
             {
             $r_code =2;
             $r_message = "FC port $fc_port swFCPortOprStatus is $port_opr_state{$port_opr_state_key} and NOT disabled. Please check cables and partner host";
             }
          if ( $port_link_state == 2 )
             {
             $r_code = 0;
             $r_message = "FC port $fc_port swFCPortOprStatus is $port_opr_state{$port_opr_state_key} and disabled.";
             }
          if ( $port_link_state == 3 )
             {
             $r_code = 0;
             $r_message = "FC port $fc_port swFCPortOprStatus is $port_opr_state{$port_opr_state_key} and loopback.";
             }
          }

       if ( $port_opr_state_key == 4 )
          {
          $r_code = 2;
          $r_message = "FC port $fc_port swFCPortOprStatus is $port_opr_state{$port_opr_state_key}";
          }
       }
    else
       {
       $r_code = 2;
       $r_message = "FC port $fc_port not possible to get operational state of the port.";
       }
    }


sub FW_Lic()
    {
    # Fabric Watch licensed?
    # 1 - swFwLicensed
    # 2 - swFwNotLicensed
    $oid = ".1.3.6.1.4.1.1588.2.1.1.1.10.1.0";
    $result = get_request();
    return $$result{$oid};
    }


sub get_out()
    {
    my $exitcode;
    my $msg2nagios;

    $exitcode = "$_[0]";
    $msg2nagios = "$_[1]";

    print "$msg2nagios";

    # Don't forget to close the session to be clean.
    $session->close();

    exit $exitcode;
    }


sub usage()
    {
    print "Usage: ";
    print "$progname ";
    print "[ -H <host> ] ";
    print "[ -C|--community=<community> ] ";
    print "[ -v|--snmpversion=<1|2c|3> ] ";
    print "[ -L|--seclevel=<noAuthNoPriv|authNoPriv|authPriv> ] ";
    print "[ -a|--authproto=<MD5|SHA> ] ";
    print "[ -x|--privproto=<DES|AES> ] ";
    print "[ -U|--secname=<username> ] ";
    print "[ -A|--authpassword=<password> ] ";
    print "[ -X|--privpasswd=<password> ] ";
    print "[ -n|--context=<contextname> ] ";
    print "[--port=<SNMP portnumber>] ";
    print "[ -P|--fc-port=<fcport-number>] | ";
    print "[-s|--systeminfo";
    print " [ --sensor ]] ";
    print "| [[ --sfptemp ] ";
    print "[--sfptemp_warn=<offset>] ";
    print "[--maxsfptemp=<temperature>] ";
    print "[--allports]] ";
    print "[ -p|--performancedata ] ";
    print "[--multiline]\n\n";
    }


sub help ()
    {
    print "This monitoring plugin is free software, and comes with ABSOLUTELY NO WARRANTY.\n";
    print "It may be used, redistributed and/or modified under the terms of the GNU\n";
    print "General Public Licence (see http://www.fsf.org/licensing/licenses/gpl.txt).\n\n";
    
    usage();

    print "This plugin check the selected FC-port of a Brocade (branded or unbranded) fibrechannel switch\n\n";

    print "-h, --help                  Print detailed help screen\n";
    print "-V, --version               Print version information\n";
    print "-H, --hostname=STRING       Hostname/IP-Adress to use for the check.\n";
    print "-C, --community=STRING      SNMP community that should be used to access the switch.\n";
    print "-v, --snmpversion=STRING    Possible values are 1, 2c or 3.\n";
    print "-L, --seclevel=STRING       SNMPv3 securityLevel (noAuthNoPriv|authNoPriv|authPriv)\n";
    print "-a, --authproto=STRING      SNMPv3 auth proto (MD5|SHA)\n";
    print "-x, --privproto=STRING      SNMPv3 priv proto (DES|AES) (default: DES)\n";
    print "-U, --secname=STRING        SNMPv3 username\n";
    print "-A, --authpassword=STRING   SNMPv3 authentication password\n";
    print "-X, --privpasswd=STRING     SNMPv3 privacy password\n";
    print "-n, --context=STRING        SNMPv3 context name\n";
    print "    --port=INTEGER          If other than 161 (default) is used)\n";
    print "-P, --fc-port=INTEGER       Port number as shown in the output of `switchshow`.Can't combine with -s\n\n";
    print "-s, --systeminfo            Get global data like boot date, overall status, reachability etc.\n";
    print "    --sensor                Additional to -s. Status of powersupply, fans and temp sensors.\n";
    print "    --global                Global data like boot date, overall status etc.\n";
    print "\n";
    print "-p, --performancedata       Print performance data of the selected FC port.\n";
    print "    --sfptemp               Checks the temperature of all SFPs.\n";
    print "    --sfptemp_warn=INT      This is the warning offset the critical temperature as delivered\n";
    print "                            by the system. Default is $SFP_TempHighWarn_def Celsius.\n";
    print "                            MUST be used with --sfptemp.\n";
    print "    --maxsfttemp            Maximum temperature for SFPs. If not set it will be taken from\n";
    print "                            your switch.\n";
    print "    --allports              Default is only to show ports which are too hot. With this flag all ports\n";
    print "                            will be shown. MUST be used with --sfptemp.\n";
    print "    --multiline             Multiline output in overview. This mean technically that a multiline\n";
    print "                            output uses a HTML <br> for the GUI instead of \\n\n";
    print "                            Be aware that your messing connections (email, SMS...) must use\n";
    print "                            a filter to file out the <br>. A sed oneliner will do the job.\n";
    }


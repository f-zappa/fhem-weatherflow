#
# $Id: 59_WeatherFlow.pm 2020-11-23 f-zappa
#
# #####
# captures UDP broadcast messages sent by a weatherflow hub
# designed for and tested with tempest weather station
# should also support older weatherflow smart weather station (untested yet)
#
# #####
# Author: Uli Baumann <fhem at uli-baumann dot de>
# Source: https://github.com/f-zappa/fhem-weatherflow
# API reference: https://weatherflow.github.io/Tempest/api/udp/v143/
#
# #####
# version history
# v0.2 2020-11-23
# * documentation was improved
# v0.1 2020-11-22
# * initial implementation; basic functionality
# * much of the code was "borrowed" from 37_dash_dhcp.pm by justme1968

package main;

use strict;
use warnings;
use feature "switch";
use JSON;
use IO::Socket::INET;

sub weatherflow_Initialize($) {
  my ($hash) = @_;
  $hash->{ReadFn}   = "weatherflow_Read";
  $hash->{DefFn}    = "weatherflow_Define";
  $hash->{NOTIFYDEV}= "global";
  $hash->{NotifyFn} = "weatherflow_Notify";
  $hash->{UndefFn}  = "weatherflow_Undefine";
  $hash->{AttrFn}   = "weatherflow_Attr";
  $hash->{AttrList} = "disable:1,0 disabledForIntervals serials port altitude $readingFnAttributes";
}

#####################################

sub weatherflow_Define($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  return "Usage: define <name> weatherflow"  if(@a != 2);
  my $name = $a[0];
  $hash->{NAME} = $name;
  if( $init_done ) {
    weatherflow_startListener($hash);
  } else {
    readingsSingleUpdate($hash, 'state', 'initialized', 1 );
  }
  return undef;
}

sub weatherflow_Notify($$) {
  my ($hash,$dev) = @_;
  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));
  weatherflow_startListener($hash);
  return undef;
}

sub weatherflow_startListener($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  weatherflow_stopListener($hash);
  return undef if( IsDisabled($name) > 0 );
  $hash->{PORT} = 50222; # weatherflow hub broadcasts on port 50222
  $hash->{PORT} = AttrVal($name, 'port', $hash->{PORT});
  Log3 $name, 3, "$name: using port $hash->{PORT}";
  if( my $socket = IO::Socket::INET->new(LocalPort=>$hash->{PORT}, Proto=>'udp', ReusePort=>1) ) {
    readingsSingleUpdate($hash, 'state', 'listening', 1 );
    Log3 $name, 3, "$name: listening";
    $hash->{LAST_CONNECT} = FmtDateTime( gettimeofday() );
    $hash->{FD}    = $socket->fileno();
    $hash->{CD}    = $socket;         # sysread / close won't work on fileno
    $hash->{CONNECTS}++;
    $selectlist{$name} = $hash;
  } else {
    Log3 $name, 2, "$name: failed to open port $hash->{PORT} $@";
    weatherflow_stopListener($hash);
    InternalTimer(gettimeofday()+30, "weatherflow_startListener", $hash, 0);
  }
}

sub weatherflow_stopListener($) {
  my ($hash) = @_;
  my $name   = $hash->{NAME};
  RemoveInternalTimer($hash);
  return if( !$hash->{CD} );
  close($hash->{CD}) if($hash->{CD});
  delete($hash->{FD});
  delete($hash->{CD});
  delete($selectlist{$name});
  readingsSingleUpdate($hash, 'state', 'stopped', 1 );
  Log3 $name, 3, "$name: stopped";
  $hash->{LAST_DISCONNECT} = FmtDateTime( gettimeofday() );
}

sub weatherflow_Undefine($$) {
  my ($hash, $arg) = @_;
  weatherflow_stopListener($hash);
  return undef;
}

sub weatherflow_slp($$$) {
  # convert station pressure to sea level pressure
  # https://de.wikipedia.org/wiki/Barometrische_H%C3%B6henformel
  my ($pressure,$temp,$alt) = @_;
  return sprintf("%.2f", $pressure*(($temp+273.15)/($temp+273.15+0.0065*$alt))**(-5.255));
}

sub weatherflow_Parse($$;$) {
  my ($hash,$rawdata,$peerhost) = @_;
  my $name = $hash->{NAME};
    Log3 $name, 5, "$name: $rawdata";
  my $message = eval{decode_json(encode_utf8($rawdata))};
  # catch error from eval
  my $evalErr = $@;
  if (not defined($message))
    {
       my $err = "error decoding content";
       $err = $err . ": " . $evalErr if (defined ($evalErr));
       Log3 ($name, 2, $err);
       return undef;
    }
  # do we care for this device serial number?
  if (AttrVal($name,"serials","") =~ /$message->{serial_number}/) {
    # get altitude (needed for pressure conversion)
    my $altitude=AttrVal($name,'altitude',AttrVal('global','altitude',0));
    given($message->{type}) {
      # update readings according to message type
      when("evt_precip") { # RAIN START EVENT
        singleReadingsUpdate($hash,"precip_started",$message->{evt},1);
      }
      when("rapid_wind") { # RAPID WIND
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"rapid_wind_speed",$message->{ob}[1]);
        readingsBulkUpdate($hash,"rapid_wind_direction",$message->{ob}[2]);
        readingsEndUpdate($hash,1)
      }
      when("evt_strike") { # LIGHTNING STRIKE EVENT
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"lightning_strike_distance",$message->{evt}[1]);
        readingsBulkUpdate($hash,"lightning_strike_energy",$message->{evt}[2]);
        readingsEndUpdate($hash,1)
      }
      when("light_debug") { # LIGHTNING DEBUGGING DATA
        # ignore this message - not documented in API
      }
      when("hub_status") { # HUB STATUS
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"hub_firmware",$message->{firmware_revision});
        readingsBulkUpdate($hash,"hub_uptime",$message->{uptime});
        readingsBulkUpdate($hash,"hub_rssi",$message->{rssi});
        readingsBulkUpdate($hash,"hub_rssi",$message->{rssi});
        readingsEndUpdate($hash,1)
	# message has more fields, though don't seem useful. see weatherflow API.
      }
      when("obs_st") { # WEATHER OBSERVATION (TEMPEST)
        my $alt = 
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"wind_lull",$message->{obs}[0][1]);
        readingsBulkUpdate($hash,"wind_avg",$message->{obs}[0][2]);
        readingsBulkUpdate($hash,"wind_gust",$message->{obs}[0][3]);
        readingsBulkUpdate($hash,"wind_direction",$message->{obs}[0][4]);
        readingsBulkUpdate($hash,"wind_sample_interval",$message->{obs}[0][5]);
        readingsBulkUpdate($hash,"station_pressure",$message->{obs}[0][6]);
        readingsBulkUpdate($hash,"temperature",$message->{obs}[0][7]);
        readingsBulkUpdate($hash,"humidity",$message->{obs}[0][8]);
        readingsBulkUpdate($hash,"illuminance",$message->{obs}[0][9]);
        readingsBulkUpdate($hash,"uv",$message->{obs}[0][10]);
        readingsBulkUpdate($hash,"solar_radiation",$message->{obs}[0][11]);
        readingsBulkUpdate($hash,"precip_accumulated",$message->{obs}[0][12]);
        readingsBulkUpdate($hash,"precip_type",$message->{obs}[0][13]);
        readingsBulkUpdate($hash,"lightning_avg_distance",$message->{obs}[0][14]);
        readingsBulkUpdate($hash,"lightning_strike_count",$message->{obs}[0][15]);
        readingsBulkUpdate($hash,"tempest_battery",$message->{obs}[0][16]);
        readingsBulkUpdate($hash,"tempest_report_interval",$message->{obs}[0][17]);
        readingsBulkUpdate($hash,"tempest_firmware",$message->{firmware_revision});
        readingsBulkUpdate($hash,"pressure",weatherflow_slp($message->{obs}[0][6],$message->{obs}[0][7],$altitude));
        readingsEndUpdate($hash,1)
      }
      when("obs_air") { # WEATHER OBSERVATION (AIR SENSOR)
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"station_pressure",$message->{obs}[0][1]);
        readingsBulkUpdate($hash,"temperature",$message->{obs}[0][2]);
        readingsBulkUpdate($hash,"humidity",$message->{obs}[0][3]);
        readingsBulkUpdate($hash,"lightning_strike_count",$message->{obs}[0][4]);
        readingsBulkUpdate($hash,"lightning_avg_distance",$message->{obs}[0][5]);
        readingsBulkUpdate($hash,"air_battery",$message->{obs}[0][6]);
        readingsBulkUpdate($hash,"air_report_interval",$message->{obs}[0][7]);
        readingsBulkUpdate($hash,"pressure",weatherflow_slp($message->{obs}[0][1],$message->{obs}[0][2],$altitude));
        readingsEndUpdate($hash,1)
      }
      when("obs_sky") { # WEATHER OBSERVATION (SKY SENSOR)
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"illuminance",$message->{obs}[0][1]);
        readingsBulkUpdate($hash,"uv",$message->{obs}[0][2]);
        readingsBulkUpdate($hash,"rain_accumulated",$message->{obs}[0][3]);
        readingsBulkUpdate($hash,"wind_lull",$message->{obs}[0][4]);
        readingsBulkUpdate($hash,"wind_avg",$message->{obs}[0][5]);
        readingsBulkUpdate($hash,"wind_gust",$message->{obs}[0][6]);
        readingsBulkUpdate($hash,"wind_direction",$message->{obs}[0][7]);
        readingsBulkUpdate($hash,"sky_battery",$message->{obs}[0][8]);
        readingsBulkUpdate($hash,"sky_report_interval",$message->{obs}[0][9]);
        readingsBulkUpdate($hash,"solar_radiation",$message->{obs}[0][10]);
        readingsBulkUpdate($hash,"local_day_rain_accumulation",$message->{obs}[0][11]);
        readingsBulkUpdate($hash,"precipitation_type",$message->{obs}[0][12]);
        readingsBulkUpdate($hash,"wind_sample_interval",$message->{obs}[0][13]);
        readingsEndUpdate($hash,1)
      }
      when("device_status") { # SENSOR STATUS (TEMPEST, AIR SKY)
	my $sensor;
	given(substr($message->{serial_number},0,2)) {
          when('AR') {$sensor="air"}
          when('SK') {$sensor="sky"}
          when('ST') {$sensor="tempest"}
	  default    {$sensor="unknown"}
          }
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,$sensor."_uptime",$message->{uptime});
        readingsBulkUpdate($hash,$sensor."_voltage",$message->{voltage});
        readingsBulkUpdate($hash,$sensor."_firmware",$message->{firmware_revision});
        readingsBulkUpdate($hash,$sensor."_rssi",$message->{rssi});
        readingsBulkUpdate($hash,$sensor."_hub_rssi",$message->{hub_rssi});
        # todo: evaluate status, see API
        readingsBulkUpdate($hash,$sensor."_status",$message->{sensor_status});
        readingsBulkUpdate($hash,$sensor."_debug",$message->{debug});
        readingsEndUpdate($hash,1)
      }
      default {
        Log3 $name,3,"$name received unknown message type <$message->{type}>";
      #	readingsSingleUpdate($hash,"rawdata",$rawdata,1)
      }	
    }
  }
  # add "new" serial numbers to reading
  elsif (not ReadingsVal($name,"known_serials","") =~ /$message->{serial_number}/)
    {
      readingsSingleUpdate($hash,"known_serials",ReadingsVal($name,"known_serials","")." ".$message->{serial_number},1);
    }
}

sub weatherflow_Read($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $len;
  my $buf;
  Log3 $name,5,"$name read raw data";
  $len = $hash->{CD}->recv($buf, 4096);
  if( !defined($len) || !$len ) {
    Log3 $name,2,"$name captured invalid weatherflow packet";
    return;
  }
  weatherflow_Parse($hash, $buf);
}

sub weatherflow_Attr($$$) {
  my ($cmd, $name, $attrName, $attrVal) = @_;
  my $orig = $attrVal;
  my $hash = $defs{$name};
  if( $attrName eq "disable" ) {
    # start/stop device if this value is changed
    if( $cmd eq 'set' && $attrVal ne "0" ) {
      weatherflow_stopListener($hash);
    } else {
      $attr{$name}{$attrName} = 0;
      weatherflow_startListener($hash);
    }
  } elsif( $attrName eq "disabledForIntervals" ) {
    delete $attr{$name}{$attrName};
    $attr{$name}{$attrName} = $attrVal if( $cmd eq 'set' );
    weatherflow_startListener($hash);
  } elsif( $attrName eq "port" ) {
    delete $attr{$name}{$attrName};
    $attr{$name}{$attrName} = $attrVal if( $cmd eq 'set' );
    weatherflow_startListener($hash);
  } elsif( $attrName eq "altitude" ) {
    delete $attr{$name}{$attrName};
    $attr{$name}{$attrName} = $attrVal if( $cmd eq 'set' );
  }
  if( $cmd eq 'set' ) {
    if( $orig ne $attrVal ) {
      $attr{$name}{$attrName} = $attrVal;
      return $attrName ." set to ". $attrVal;
    }
  }
  return;
}

1;

=pod
=item device
=item summary Receive local weather data from a WeatherFlow station 
=item summary_DE Wetterstation von WeatherFlow auslesen
=begin html

<a name="WeatherFlow"></a>
<h3>WeatherFlow</h3>
<ul>
  This module listens to broadcast messages sent out by the WeatherFlow hub. It has been
  designed and tested for the <a href="https://weatherflow.com/tempest-weather-system/">
  Tempest Weather System</a>, but should also be capable to work with the older
  WeatherFlow Smart Weather Station.<br>
  Docker users please note that you will need to map udp port 50222 to the FHEM container.
<br></ul>

<a name="WeatherFlow_Define"></a>
<h4>Define</h4>
<ul>
  <code>define &lt;name&gt; weatherflow</code>
<br><br>
  After defining the device, watch the "known_serials" reading which will collect all
  WeatherFlow serial numbers visible in your network. You will see at least one
  hub instance ("HB-xxxxxxxx") and either one Tempest instance ("ST-xxxxxxxx") or the
  Sky and Air instances ("SK-xxxxxxxx" and "AR-xxxxxxxx"). Most likely you will only see
  your own devices, otherwise see the stickers on your hardware to figure out the
  serial numbers. Then apply these to the module:
<br>
  <code>attr wetterstation serials HB-xxxxxxxx ST-xxxxxxxx</code>
<br></ul>

<a name="weatherflow_Attr"></a>
<h4>Attr</h4>
<ul>
<li>serials<br>
  The hardware serial numbers, usually important if your hub can receive more than
  one weather station. Only use one Tempest or one combination Air-Sky per instance, 
  otherwise the data will be overwritten alternately. You may also include
  hub serial number to read corresponding data. </li>
<li>altitude<br>
  This value is needed to derive <i>sea level pressure</i> from the measured
  <i>station_pressure</i>. If unset, the <i>altitude</i> attribute in the 
  <a href="#global">global device</a> is used, so consider to set the correct
  altitude there. <br>
  On the other hand, you may want to overwrite this value here (eg. if
  your stations altitude differs from the global value). </li> 
<li>port<br>
  WeatherFlow data is usually transmitted on udp/50222, however, you may change here
  if needed.</li>
<li><a href="#disable">disable</a></li>
<li><a href="#disabledForIntervals">disabledForIntervals</a></li>
</ul><br>

=end html

=begin html_DE

<a name="WeatherFlow"></a>
<h3>WeatherFlow</h3>
<ul>
  Dieses Modul emf&auml;ngt Broadcast-Nachrichten, die von einem WeatherFlow-Hub gesendet
  werden. Es wurde entwickelt und getestet fuer die 
  <a href="https://weatherflow.com/tempest-weather-system/">
  Tempest</a>-Wetterstation, sollte aber auch mit der &auml;lteren
  WeatherFlow Smart Weather Station arbeiten.<br>
  Falls Docker eingesetzt wird, muss der Port 50222/udp in den Container gemappt werden.
<br></ul>

<a name="WeatherFlow_Define"></a>
<h4>Define</h4>
<ul>
  <code>define &lt;name&gt; weatherflow</code>
<br><br>
  Nach der Definition werden die Seriennummern alle im lokalen Netzwerk sichtbaren 
  WeatherFlow-Geraete im Reading "known_serials" gesammelt. Darunter sollte mindestens
  ein Hub ("HB-xxxxxxxx") and entweder ein Tempest-Sensor ("ST-xxxxxxxx") oder die
  Sky- and Air-Sensoren  ("SK-xxxxxxxx" and "AR-xxxxxxxx") sein. Wahrscheinlich sieht
  man nur die eigenen Devices, ansonsten helfen die Aufkleber auf der Hardware.
  Die Seriennummern werden dann in das Modul eingetragen:
<br><br>
  <code>attr wetterstation serials HB-xxxxxxxx ST-xxxxxxxx</code>
<br></ul>

<a name="weatherflow_Attr"></a>
<h4>Attr</h4>
<ul>
<li>serials<br>
  Die Hardware-Seriennummern werden ben&ouml;tigt, da der Hub unter Umst&auml;nden mehrere 
  Wetterstationen empf&auml;ngt. Hier sollten nur eine Tempest ODER eine Kombination
  Air-Sky eingetragen sein, da bei mehreren Geraeten die Daten wechselseitig
  &uuml;berschrieben w&uuml;rden. Auch die Hub-Seriennummer kann hinzugef&uuml;gt werden,
  um dessen Daten auslesen zu koennen.</li>
<li>altitude<br>
  Mit Hilfe der H&ouml;henangabe wird der lokal gemessene Luftdruck auf das
  &Auml;quivalent bei Meeresh&ouml;he umgerechnet. Normalerweise sollte dieser Wert
  im Attribut <i>altitude</i> im <a href="#global">global device</a> stehen.<br>
  An dieser Stelle kann dieser Wert &uuml;berschrieben werden (z.B. falls die H&ouml;he
  der Wetterstation sich von der global gesetzten H&ouml;he stark unterscheidet).</li>
<li>port<br>
  Normalerweise erwarten wir WeatherFlow-Daten auf udp/50222, aber falls erforderlich kann
  dies hier ge&auml;ndert werden.</li>
<li><a href="#disable">disable</a></li>
<li><a href="#disabledForIntervals">disabledForIntervals</a></li>
</ul>
=end html_DE

=cut

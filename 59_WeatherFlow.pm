
# $Id: 59_weatherflow.pm 
#
# captures UDP broadcast messages sent by a weatherflow hub
# API reference: https://weatherflow.github.io/Tempest/api/udp/v143/
#
package main;

use strict;
use warnings;
use feature "switch";
use JSON;
use IO::Socket::INET;

sub
weatherflow_Initialize($)
{
  my ($hash) = @_;
  $hash->{ReadFn}   = "weatherflow_Read";
  $hash->{DefFn}    = "weatherflow_Define";
  $hash->{NOTIFYDEV} = "global";
  $hash->{NotifyFn} = "weatherflow_Notify";
  $hash->{UndefFn}  = "weatherflow_Undefine";
  $hash->{AttrFn}   = "weatherflow_Attr";
  $hash->{AttrList} = "disable:1,0 disabledForIntervals serials port altitude $readingFnAttributes";
}

#####################################

sub
weatherflow_Define($$)
{
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

sub
weatherflow_Notify($$)
{
  my ($hash,$dev) = @_;
  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));
  weatherflow_startListener($hash);
  return undef;
}

sub
weatherflow_startListener($)
{
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

sub
weatherflow_stopListener($)
{
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

sub
weatherflow_Undefine($$)
{
  my ($hash, $arg) = @_;
  weatherflow_stopListener($hash);
  return undef;
}

sub weatherflow_slp($$$)
{
  # https://de.wikipedia.org/wiki/Barometrische_H%C3%B6henformel
  my ($pressure,$temp,$alt) = @_;
  return sprintf("%.2f", $pressure*(($temp+273.15)/($temp+273.15+0.0065*$alt))**(-5.255));
}

sub
weatherflow_Parse($$;$)
{
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
        # ignore this message
      }
      when("hub_status") { # HUB STATUS
        readingsBeginUpdate($hash);
        readingsBulkUpdate($hash,"hub_firmware",$message->{firmware_revision});
        readingsBulkUpdate($hash,"hub_uptime",$message->{uptime});
        readingsBulkUpdate($hash,"hub_rssi",$message->{rssi});
        readingsBulkUpdate($hash,"hub_rssi",$message->{rssi});
        readingsEndUpdate($hash,1)
	# message has more fields, though don't seem useful. see weatherflow docs.
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
        # todo: evaluate status
        readingsBulkUpdate($hash,$sensor."_status",$message->{sensor_status});
        readingsBulkUpdate($hash,$sensor."_debug",$message->{debug});
        readingsEndUpdate($hash,1)
      }
      #default {
      #	readingsSingleUpdate($hash,"rawdata",$rawdata,1)
      #}	
    }
  }
  # add "new" serial numbers to reading
  elsif (not ReadingsVal($name,"known_serials","") =~ /$message->{serial_number}/)
    {
      readingsSingleUpdate($hash,"known_serials",ReadingsVal($name,"known_serials","")." ".$message->{serial_number},1);
    }
}

sub
weatherflow_Read($)
{
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

sub
weatherflow_Attr($$$)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;

  my $orig = $attrVal;

  my $hash = $defs{$name};
  if( $attrName eq "disable" ) {
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
=item summary    Receive local weather data from a WeatherFlow station 
=item summary_DE Wetterstation von WeatherFlow auslesen
=begin html

<a name="WeatherFlow"></a>
<h3>WeatherFlow</h3>
<ul>
  This module listens to broadcast messages sent out by the WeatherFlow hub. It has been
  designed and tested for the <a href="https://weatherflow.com/tempest-weather-system/">
  Tempest Weather System</a>, but should also be capable to work with the older
  WeatherFlow Smart Weather Station.
  Docker users please note that you will need to map udp port 50222 to the FHEM container.
<br><br>
</ul>
<a name="WeatherFlow_Define"></a>
<b>Define</b>
<ul>
<code>define &lt;name&gt; weatherflow</code>
<br><br>
Example: <code>define wetterstation weatherflow</code>
<br><br>
After defining the device, watch the "known_serials" reading which will collect all
WeatherFlow serial numbers visible in your network. You will see at least one
hub instance ("HB-xxxxxxxx") and either one Tempest instance ("ST-xxxxxxxx") or the
Sky and Air instances ("SK-xxxxxxxx" and "AR-xxxxxxxx"). Most likely you will only see
your own devices, otherwise see the stickers on your hardware to figure out the
serial numbers. Then apply these to the module:
<br><br>
Example: <code>attr wetterstation serials HB-xxxxxxxx ST-xxxxxxxx</code>
<br><br>
</ul>
<a name="weatherflow_Attr"></a>
<b>Attr</b>
<ul>
<li>serials<br>
The hardware serial numbers, usually important if your hub can receive more than
one weather station. Only use one Tempest or one combination Air-Sky per instance, 
otherwise the data will be overwritten alternately. You may also include
hub serial number to read corresponding data.
<li>altitude<br>
This value is needed to derive <i>sea level pressure</i> from the measured
<i>station_pressure</i>. If unset, the <i>altitude</i> attribute in the 
<a href="#global">global device</a> is used, so consider to set the correct
altitude there. On the other hand, you may overwrite this value here (eg. if
your stations altitude differs from the global value). 
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
  Dieses Modul emfaengt Broadcast-Nachrichten, die von einem WeatherFlow-Hub gesendet
  werden. Es wurde entwickelt und getestet fuer die 
  <a href="https://weatherflow.com/tempest-weather-system/">
  Tempest</a>-Wetterstation, sollte aber auch mit den aelteren
  WeatherFlow Smart Weather Stationen arbeiten.
  Falls Docker eingesetzt wird, muss der Port 50222/udp in den Container gemappt werden.
<br><br>
</ul>
<a name="WeatherFlow_Define"></a>
<b>Define</b>
<ul>
<code>define &lt;name&gt; weatherflow</code>
<br><br>
Example: <code>define wetterstation weatherflow</code>
<br><br>
Nach der Definition werden die Seriennummern alle im lokalen Netzwerk sichtbaren 
WeatherFlow-Geraete im Reading "known_serials" gesammelt. Darunter sollte mindestens
ein Hub ("HB-xxxxxxxx") and entweder ein Tempest-Sensor ("ST-xxxxxxxx") oder die
Sky- and Air-Sensoren  ("SK-xxxxxxxx" and "AR-xxxxxxxx") sein. Wahrscheinlich sieht
man nur die eigenen Devices, ansonsten helfen die Aufkleber auf der Hardware.
Die Seriennummern werden dann in das Modul eingetragen:
<br><br>
Example: <code>attr wetterstation serials HB-xxxxxxxx ST-xxxxxxxx</code>
<br><br>
</ul>
<a name="weatherflow_Attr"></a>
<b>Attr</b>
<ul>
<li>serials<br>
Die Hardware-Seriennummern sind wichtig, da der Hub unter Umstaenden mehrere 
Wetterstationen empfaengt. Hier sollten nur eine Tempest ODER eine Kombination
Air-Sky eingetragen sein, da bei mehreren Geraeten die Daten wechselseitig
ueberschrieben werden. Auch die Hub-Seriennummer kann hinzugefuegt werden, um
dessen Daten auslesen zu koennen.
<li>altitude<br>
Die Hoehe wird benoetigt, um den lokal gemessenen Luftdruck auf Meereshoehe
umzurechnen. Ist dieser Wert hier nicht gesetzt, wird das Attribut
<i>altitude</i> im <a href="#global">global device</a> verwendet, wo er eigentlich auch
hingehoert. Andererseits kann dieser Wert hier ueberschrieben werden (z.B. falls die
Hoehe der Wetterstation sich von der global gesetzten Hoehe stark unterscheidet).
<li>port<br>
Normalerweise uebertraegt der WeatherFlow-Hub auf udp/50222, aber falls noetig, kann
dies hier geaendert werden.</li>
<li><a href="#disable">disable</a></li>
<li><a href="#disabledForIntervals">disabledForIntervals</a></li>
</ul><br>
=end html_DE

=cut

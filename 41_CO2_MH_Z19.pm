package main;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use Data::Dumper;

my %sets = (
  "calibrate" => "textField",
  "selfCalibration" => "on,off",
  "reopen" => "noArg",
 );
 
 my %gets = (
  "deviceInfo"      => "noArg",
  "update"			=> "noArg"
);


sub CO2_MH_Z19_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

  $hash->{DefFn}     = 	"CO2_MH_Z19_Define";
  $hash->{AttrFn}    = 	"CO2_MH_Z19_Attr";
  $hash->{SetFn}     = 	"CO2_MH_Z19_Set";
  $hash->{GetFn}     = 	"CO2_MH_Z19_Get";
  $hash->{AttrList}  = 	"tempOffset interval ".
												"$readingFnAttributes";
}
################################### Todo: Set or Attribute for Mode? Other sets needed?
sub CO2_MH_Z19_Set($@) {					#

	my ( $hash, $name, @args ) = @_;

	### Check Args
	my $numberOfArgs  = int(@args);
	return "CO2_MH_Z19_Set: No cmd specified for set" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;
	if (!exists($sets{$cmd}))  {
		my @cList;
		foreach my $k (keys %sets) {
			my $opts = undef;
			$opts = $sets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		}
		return "CO2_MH_Z19_Set: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling
	
	if ( $cmd eq "reopen") {
		CO2_MH_Z19_Reopen($hash);
		return undef;
	}
	if ( $cmd eq "calibrate") {
		my $arg = shift @args;
		return "Type yes if you really want to start the device calibration" if !defined $arg || $arg ne "yes";
		CO2_MH_Z19_Send($hash,0x87,0);
		return undef;
	}
	if ( $cmd eq "selfCalibration") {
		my $arg = shift @args;
		return if !defined $arg;
		if ($arg eq "on") {
			CO2_MH_Z19_Send($hash,0x79,0xa0);
		} elsif ($arg eq "off") {
			CO2_MH_Z19_Send($hash,0x79,0x00);
		}
		CO2_MH_Z19_DeviceInfo($hash); #Read changes back into readings
	}

	return undef;
}

sub CO2_MH_Z19_Reopen($) {
    my ($hash) = @_;
	Log3 $hash->{NAME}, 3, "Reopening serial device";
    DevIo_CloseDev($hash);
    sleep(1);
    DevIo_OpenDev( $hash, 0, "CO2_MH_Z19_DoInit" );
}

################################### 
sub CO2_MH_Z19_Get($@) {
	my ($hash, $name, @args) = @_;
	
	my $numberOfArgs  = int(@args);
	return "CO2_MH_Z19_Get: No cmd specified for get" if ( $numberOfArgs < 1 );

	my $cmd = shift @args;

	if (!exists($gets{$cmd}))  {
		my @cList;
		foreach my $k (keys %gets) {
			my $opts = undef;
			$opts = $gets{$k};

			if (defined($opts)) {
				push(@cList,$k . ':' . $opts);
			} else {
				push (@cList,$k);
			}
		}
		return "Signalbot_Get: Unknown argument $cmd, choose one of " . join(" ", @cList);
	} # error unknown cmd handling
	
	my $arg = shift @args;
	
	if ($cmd eq "deviceInfo") {
		return CO2_MH_Z19_DeviceInfo($hash);
		return undef;
	} elsif ($cmd eq "update") {
		CO2_MH_Z19_Send($hash,0x86,0);
		CO2_MH_Z19_Update($hash);
		return undef;
	}

	return undef;
}

################################### 
sub CO2_MH_Z19_Attr(@) {					#
	my ($command, $name, $attr, $val) = @_;
	my $hash = $defs{$name};
	my $msg = undef;
	Log3 $hash->{NAME}, 5, $hash->{NAME}.": Attr $attr=$val"; 
	if ($attr eq 'interval') {
		if ( defined($val) ) {
			if ( looks_like_number($val) && $val >= 0) {
				RemoveInternalTimer($hash);
				InternalTimer(gettimeofday()+1, 'CO2_MH_Z19_Execute', $hash, 0) if $val>0;
			} else {
				$msg = "$hash->{NAME}: Wrong poll intervall defined. interval must be a number >= 0";
			}    
		} else {
			RemoveInternalTimer($hash);
		}
	}
	return undef;	
}

sub CO2_MH_Z19_DoInit($) {					#
    my $hash = shift;
	Log3 $hash->{NAME}, 3, "Init Co2 Sensor";
	CO2_MH_Z19_DeviceInfo($hash);
	return undef;
}

sub CO2_MH_Z19_DeviceInfo($) {					#
    my $hash = shift;
    my $name = $hash->{NAME};
	my @buf;
	
	Log3 $hash->{NAME}, 3, "Init Co2 DeviceInfo";
	CO2_MH_Z19_Send($hash,0xa0,0);
	@buf=CO2_MH_Z19_Read($hash);
	return "Error reading from device" if @buf!=8;
	my $firmware=chr($buf[2]).chr($buf[3]).chr($buf[4]).chr($buf[5]);
	Log3 $hash->{NAME}, 5, "Firmware:".$firmware;
	CO2_MH_Z19_Send($hash,0x7D,0);
	@buf=CO2_MH_Z19_Read($hash);
	return "Error reading from device" if @buf!=8;
	my $cal=$buf[7];
	Log3 $hash->{NAME}, 5, "Self Calibration:".(($cal==1)?'on':'off');
	CO2_MH_Z19_Send($hash,0x9B,0);
	@buf=CO2_MH_Z19_Read($hash);
	return "Error reading from device" if @buf!=8;
	my $range = $buf[4]*256+$buf[5];
	Log3 $hash->{NAME}, 5, "Range:".$range;
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "Firmware", $firmware);
	readingsBulkUpdate($hash, "Range", $range);
	readingsBulkUpdate($hash, "SelfCalibration", (($cal==1)?'on':'off'));
	readingsEndUpdate($hash, 1);	
}

#Periodic read part 1 - request data from sensor - then wait 1 second for data to become ready
sub CO2_MH_Z19_Execute($) {
    my $hash = shift;
	CO2_MH_Z19_Send($hash,0x86,0);
	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + 1, 'CO2_MH_Z19_ExecuteRead', $hash, 0);
}

#Periodic read part 2 - read data from sensor
sub CO2_MH_Z19_ExecuteRead($) {
    my $hash = shift;
	CO2_MH_Z19_Update($hash);
	RemoveInternalTimer($hash);
	my $pollInterval = AttrVal($hash->{NAME}, 'interval', 5)*60;
	InternalTimer(gettimeofday() + $pollInterval, 'CO2_MH_Z19_Execute', $hash, 0) if ($pollInterval > 0);
}

sub CO2_MH_Z19_Update($) {
    my $hash = shift;
	my $off=AttrVal($hash->{NAME},"tempOffset",0)-44;
	my @buf=CO2_MH_Z19_Read($hash);
	if (@buf==8) {
		my $co2=$buf[2]*256+$buf[3];
		my $temp=$buf[4]+$off;
		Log3 $hash->{NAME}, 5, "Co2:".$co2." temperature:".$temp;
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "co2", $co2);
		readingsBulkUpdate($hash, "state", $co2);
		readingsBulkUpdate($hash, "temperature", $temp);
		readingsEndUpdate($hash, 1);
		$hash->{helper}{retry}=5;
	} else {
		readingsSingleUpdate($hash, "state", "Error",1);
		Log3 $hash->{NAME}, 3, $hash->{NAME}." Error reading from device";
		#After 5 unsuccessful read attempts, reopen serial device. If that still fails do nothing (counter will go negative endlessly)
		my $retry=$hash->{helper}{retry};
		$retry=5 if !defined $retry;
		$retry--;
		$hash->{helper}{retry}=$retry;
		if ($retry==0) {
			CO2_MHT_Z19_Reopen($hash);
		}
	}
}

sub CO2_MH_Z19_Send($$$) {
    my $hash = shift;
    my $name = $hash->{NAME};
	my $cmd = shift;
	my $arg = shift;

	my @tx = (0xff,1,0,0,0,0,0,0);
	$tx[2]=$cmd;
	if ($cmd==0x79) { #Set selfCalibration on (0xa0) or off (0x00)
		$tx[3]=$arg;
	}
	my $checksum=0;
	for my $i (@tx) {
		$checksum+=$i;
	}
	$checksum=0xff-$checksum&0xff;
	$tx[8]=$checksum;
	my $msg=pack( 'C*', @tx);
	DevIo_SimpleWrite( $hash, $msg, 0 );
}

sub CO2_MH_Z19_Read($) {
    my $hash = shift;
    my $name = $hash->{NAME};
	my $buf = DevIo_SimpleReadWithTimeout( $hash, 1 );
	return undef if !defined $buf;
	my @ret = unpack( 'C*', $buf );
	return undef if @ret!=9;
	my $crc=pop @ret;
	my $checksum=0;
	for my $i (@ret) {
		$checksum+=$i;
	}
	$checksum=0xff-$checksum&0xff;
	return undef if $checksum!=$crc;
	return @ret;
}
	

################################### 
sub CO2_MH_Z19_Define($$) {			#
	my ($hash, $def) = @_;
	
	my @a = split( "[ \t][ \t]*", $def );

	if ( @a != 3 && @a != 4 ) {
        my $msg = "wrong syntax: define <name> CO2_MH_Z19 devicename";
        Log3 undef, 2, $msg;
        return $msg;
    }
	
    DevIo_CloseDev($hash);

    my $name = $a[0];
    my $dev  = $a[2];

	if (! ($dev =~ /\@/)) {
		$dev.="\@9600";
	}

    $hash->{DeviceName} = $dev;
    my $ret = DevIo_OpenDev( $hash, 0, "CO2_MH_Z19_DoInit" );
	
	RemoveInternalTimer($hash);
	my $pollInterval = AttrVal($hash->{NAME}, 'interval', 5)*60;
	InternalTimer(gettimeofday() + $pollInterval, 'CO2_MH_Z19_Execute', $hash, 0) if ($pollInterval > 0);
}

1;

#Todo Write update documentation

=pod
=item device
=item summary an interface to the MH-Z19 and related sensors
=item summary_DE Schnittstelle zum MH-Z19 und verwandte Sensoren

=begin html

<h3>CO2_MH_Z19</h3>
<a id="CO2_MH_Z19"></a>
<ul>
	interface to the MH-Z19 and related sensors. The sensor has to be attached to a serial unix device, either directly to Tx/Rx on e.g. a Raspberry using e.g. /dev/ttyAMA0 or via a USB to UART converter. Then the device can typically be found under /dev/serial/by-id/... <br>
	<a id="CO2_MH_Z19-define"></a><br>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; CO2_MH_Z19 &lt;serial device&gt;</code><br>
		Attaches the module to a serial device. Optionally a baudrate can be given, otherwise the default of 9600 baud is used.
		<br>
	</ul>
	<br>
	<a id="CO2_MH_Z19-set"></a>
	<b>Set</b>
	<ul>
		<li><b>set calibrate yes</b><br>
			<a id="CO2_MH_Z19-set-calibrate"></a>
			Switches the sensor into calibration mode. For approx. 20 minutes, the sensor will try to find the lowest CO2 measurement and assumes this to be the 400 ppm that are typical in fresh air.<br>
			Only perform this either outside or while supplying constant fresh air to the room, to avoid a wrong calibration.<br>
			The argument "yes" is used a protection against accidential use.<br>
		</li>
		<li><b>set reopen</b><br>
			<a id="CO2_MH_Z19-set-reopen"></a>
			Reopens the connection to the serial device via FHEM DevIO<br>
		</li>
		<li><b>set selfCalibration on|off</b><br>
			<a id="CO2_MH_Z19-set-selfCalibration"></a>
			Defines if the device should do constant self calibration.<br>
			This assumes that at least once every 24h the room is supplied with fresh air and the lowest measured value correspond to 400 ppm.<br>
			If you cannot guarantee that, you should rather switch this to off to avoid wrong calibration and use the "set calibrate" option in fresh air from time to time.<br>
		</li>		
	</ul>
	<br>
	<a id="CO2_MH_Z19-get"></a>
	<b>Get</b>
	<ul>
		<li><b>get deviceinfo</b><br>
		<a id="CO2_MH_Z19-get-deviceinfo"></a>
			Attempts to read some device properties like Firmware version, max. CO2 measurement Rage and status of selfCalibration and stores them in the appropriate readings.<br>
			This is automatically executed at device initialization.<br>
		</li>
		<li><b>get update</b><br>
		<a id="CO2_MH_Z19-get-update"></a>
			Manually triggers reading of CO2 and temperature values.<br>
		</li>
	</ul>
	<br>
	<a id="CO2_MH_Z19-attr"></a>
	<b>Attributes</b>
	<ul>
		<li><b>interval</b><br>
		<a id="CO2_MH_Z19-attr-interval"></a>
			Interval in minutes new CO2 and temperature values are read from the device. A value of 0 disables automatic updates.<br>
			The default is 5 minutes<br>
		</li>
		<li><b>interval</b><br>
		<a id="CO2_MH_Z19-attr-tempOffset"></a>
			The temperature sensor in the device is not very usable to measure actual room temperature.<br>
			The module attemps to apply an offset that should lead to somewhat reasonable measurements, though they might differ from device to device.<br>
			This value is added to the reading before storing it. Default is 0.<br>
		</li>

		<br>
		<br>
	</ul>
	<br>
	<a id="CO2_MH_Z19-readings"></a>
	<b>Readings</b>
	<ul>
		<br>
	<br>
</ul>

=end html

=cut

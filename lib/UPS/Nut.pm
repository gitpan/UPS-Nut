# UPS::Nut - a class to talk to a UPS via the Network Utility Tools upsd.
# Author - Kit Peters <kpeters@iname.com>

package UPS::Nut;
use strict;
use Carp;
use FileHandle;
use IO::Socket;

BEGIN {
    use Exporter ();
    use vars qw ($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    $VERSION     = 0.01; # $Id$
    @ISA         = qw(Exporter, IO::Socket::INET);
    @EXPORT      = qw ();
    @EXPORT_OK   = qw ();
    %EXPORT_TAGS = ();
}

my ($debug, # are we debugging? 
    $login, # login name to upsd
    $name, # UPS name in upsd.conf
    $host, # host running upsd
    $port, # port that upsd is running on
    $proto, # tcp or udp
    $srvsock, # socket for communicating w/ upsd
    $vars, # variables supported by upsd 
    $err, # why did it go bang?
    $timeout, # how impatient are we?
    $timedout, # did we time out?
    $master, # do we have MASTER level access?
    $instcmds, # instant commands supported by UPS
    $debugout, # where to write debug messages?
    ); # global, because I'm lazy.  :)

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my %arg = @_; # hash of arguments
  my $self = \%arg; 
  bless $self, $class;
  unless ($self->_initialize(%arg)) {
    carp "Can't initialize: $err";
    return undef;
    }
  return $self;
  }

sub _initialize { 
  my $self = shift;
  my %arg = @_;
  $name = $arg{NAME} || 'default'; # UPS name in etc/ups.conf on $host
  $host = $arg{HOST} || 'localhost'; # Host running master upsd
  $port = $arg{PORT} || '3305'; # 3305 is default port for upsd
  $proto = $arg{PROTO} || 'tcp'; # use tcp unless user tells us to
  $timeout = $arg{TIMEOUT} || 30; # timeout
  my $user = $arg{USERNAME} || undef; # username passed to upsd
  my $pass = $arg{PASSWORD} || undef; # password passed to upsd
  $debug = $arg{DEBUG} || 0; # debugging?
  $debugout = $arg{DEBUGOUT} || undef; # where to send debug messages
  $timedout = 0; # did we time out?  Set it to 0 initially.
  $login = 0; # set login to 0 initially.
  $master = 0; # no master access unless upsd says we have it.
  $srvsock = IO::Socket::INET->new(PeerAddr => $host, # connect to server
                                   PeerPort => $port,
                                   Proto    => $proto);
  my $ans; # response from upsd to various and sundry commands.  This gets 
           # reused a lot, but I don't think it's getting clobbered 
           # unnecessarily.  

  if (!$srvsock) {
    $err = "Unable to connect via $proto to $host:$port: $!"; 
    return undef;
    }

# The login logic is just unholy here.  Can I clean this up somehow?
  if ((defined $user) && (defined $pass)) { #1
    _debug("Attempting login to upsd.");
    print $srvsock "USERNAME $user\n";
    chomp($ans = <$srvsock>);
    _debug("Received $ans from upsd.");
    if ($ans =~ /^ERR/) { #2
      _debug("Login error: upsd reports $ans");
      $login = 0;
      } #2end
    elsif ($ans =~ /^OK/) { #3
      print $srvsock "PASSWORD $pass\n";
      chomp ($ans = <$srvsock>);

      if ($ans =~ /^ERR/) { #4
        _debug("Login error: upsd reports $ans");
        $login = 0;
        } #4end
      elsif ($ans =~ /^OK/) { #5
        print $srvsock "LOGIN\n";
        chomp ($ans = <$srvsock>);        

        if ($ans =~ /^ERR/) { #6
          _debug("Login error: upsd reports $ans");
          $login = 0;
          } #6end
        elsif ($ans =~ /^OK/) { #7
          _debug("LOGIN successful.  Response: $ans");
          $login = 1; # login successful!
          } #7end
        else { #8
          _debug("Sent LOGIN to upsd, received $ans");
          $login = 0;
          } #8end
        } #5end
      else { #9
        _debug("Sent PASSWORD to upsd, received $ans");
        $login = 0;
        } #9end
      } #3end
    else { #10
       _debug("Sent USERNAME to upsd, received $ans");
       $login = 0;
       } #10end
    unless ($login) {
      $err = "Login error: $ans, login functions disabled";
      carp $err;
      }
    } #1end

# get list of supported vars once, so we know what we can and 
# can't do.

   $vars = ListVars();
  } 
 
sub BattPercent() {
  my $var = "BATTPCT";
  return Request($var);
  }

sub LoadPercent() {
  my $var = "LOADPCT"; 
  return Request($var);
  }

sub LineVoltage() {
  my $var = "UTILITY";
  return Request($var);
  }  

sub Status() {
  my $var = "STATUS";
  return Request($var);
  }

sub Temperature() {
  my $var = "UPSTEMP";
  return Request($var);
  }

sub Logout() {
  if ($srvsock) {
    _debug("Sent LOGOUT to upsd");  
    print $srvsock "LOGOUT\n";
    chomp (my $ans = <$srvsock>);
    _debug("Received \"$ans\" from upsd");
    close ($srvsock);
    }
  }

sub _timeleft() {
  # Unless the load is at or very near 25% or 50%, this isn't accurate.  
  # According to Cyberpower, at 50% load, the battery will last 
  # approximately 40 minutes at full charge.  at 25% load, the 
  # battery will last approximately 100 minutes at full charge.  At loads 
  # higher than 50%, I'm told that the bettery life decreases 
  # "exponentially."  So I drew a line, connecting the two points, which 
  # is described by the function Battery life (minutes) = (-2.4 * Load 
  # Percentage) + 160.  The accuracy will improve as I get more data 
  # points. THIS IS ONLY VALID FOR CYBERPOWER 1250AVR

  if (Request("MFR") =~ /cyberpower/i) {
    warn "This data only valid for Cyberpower 1250AVR"; 
    my $load = Request("LOADPCT");  
    my $batt = Request("BATTPCT");
    my $timeleft = (-2.4 * $load) + 160;
    if ($timeleft < 0) {
      return 0;
      }
    else { return $timeleft; }
    }
  }
sub Request() {
# work on error handling
  my $var = shift;
  unless ($vars =~ /$var/i) {
    $err = "Variable $var not supported by UPS $name\n";  
    return undef;
    }

  my $req = "REQ $var@" . $name;
  my $null; # place to stick unwanted parts of a split()

  print $srvsock "$req\n";
  _debug("sending request \"$req\"");
  my $ans;
  $SIG{'ALRM'} = \&_alarmhandler;
  alarm($timeout);
  if ($timedout) { 
    $err = "Connection timed out after $timeout secs.";
    return undef;
    } 
  chomp ($ans = <$srvsock>);
  alarm(0);
  _debug("received answer \"$ans\"");
  if ($ans =~ /^ERR/) {
    $err = "Error: $ans";
    return undef;
    }
  elsif ($ans =~ /^ANS/) {
    my $checkvar; # to make sure the var we asked for is the var we got.
    my $retval; # return value
    ($null, $checkvar, $retval) = split ' ', $ans, 3;
    ($checkvar, $null) = split /@/, $checkvar, 2;
    if ($checkvar ne $var) { # is "$ans =~ /$var/" more efficient?
      $err = "requested $var, received $checkvar";
      return undef;  
      }
    return $retval;
    }
  else {
    $err = "Unrecognized response from upsd: $ans";
    return undef;
    }
  }   

sub FSD {
   my $req = "FSD " . $name;
   print $srvsock "$req\n";
   _debug ("Sent \"$req\" to upsd.");
   chomp (my $ans = <$srvsock>);
   _debug ("Received \"$ans\" from upsd.");
   if ($ans =~ /^ERR/) {
     $err = "Can't set FSD flag.  Upsd reports: $ans";
     return undef;
     }
   elsif ($ans =~ /^OK FSD-SET/) {
     _debug("FSD flag set successfully.");
     return 1;
     }
   else {
     $err = "Unrecognized response from upsd: $ans";
     return undef;
     }
   }

sub InstCmd {
   chomp (my $cmd = shift);
   unless ($instcmds =~ /$cmd/i) {
     $err = "Instant command $cmd not supported by UPS $name.";
     return undef;
     }
   my $req = "INSTCMD" . $cmd . "@" . $name;
   $err = "Can't send instant command " . $cmd . ". Reason: ";
   print $srvsock "$req\n";
   chomp (my $ans = <$srvsock>);
   if ($ans =~ /^ERR/) {
     $err .= $ans;
     return undef;
     }
   elsif ($ans =~ /^OK/) {
     _debug("Instant command $cmd sent successfully.");
     return 1;
     }
   else {
     $err .= "Unrecognized response from upsd: $ans";
     return undef;
     }
   }

sub DESTROY {
  my $self = shift;
  _debug("Object destroyed.");
  $self->Logout();
  }

sub _debug { # print debug messages to stdout or file
  if ($debug) {
    chomp (my $msg = shift);
    my $out;
    if ($debugout) {
      $out = new FileHandle ($debugout, ">>") or warn "Error: $!";
      } 
    if ($out) {
      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
      $year = sprintf("%02d", $year % 100); # Y2.1K compliant, even!
      my $timestamp = join '/', ($mon + 1), $mday, $year; # today
      $timestamp .= " ";
      $timestamp .= join ':', $hour, $min, $sec;
      print $out "$timestamp $msg\n";
      }
    else { print "DEBUG: $msg\n"; }
    }
  }

sub _alarmhandler { $timedout = 1 };

sub Error { 
  if ($err) { return $err; }
  else { return "No error explanation available."; }
  }

sub ListVars { # get list of supported variables
  my $req = "LISTVARS " . $name;
  my $availvars;
  _debug("Sending \"$req\" to upsd");
  print $srvsock "$req\n";
  chomp ($availvars = <$srvsock>);
  _debug("Received \"$availvars\" from upsd.");
  unless ($availvars =~ /^VARS/) {
    $err = "Can't get var list.  Upsd response: $availvars";
    return undef;
    }
  return $availvars;
  }

sub Master { # check for MASTER level access
  my $req = "MASTER " . $name;
  _debug ("Sending \"$req\" to upsd.");
  print $srvsock "$req\n";
  chomp (my $ans = <$srvsock>);
  _debug ("Received \"$ans\" from upsd.");
  if ($ans =~ /^OK/) {
    _debug("MASTER level access granted.  Upsd reports: $ans");
    return 1;
    }
  else {
    $err = "Upsd responded: $ans";
    return 0;
    }
  }

sub ListInstCmds { # check for available instant commands
  my $req = "LISTINSTCMD " . $name;
  _debug("Sending \"$req\" to upsd.");
  print $srvsock "$req\n";
  chomp (my $ans = <$srvsock>);
  _debug("Received \"$ans\" from upsd.");
  if ($ans =~ /^INSTCMDS/) {
    return $ans;
    }
  else {
    $err = "Upsd responded: $ans";
    return undef;
    }
  }

=head1 NAME

Nut - a module to talk to a UPS via NUT (Network UPS Tools) upsd

=head1 SYNOPSIS

 use UPS::Nut;

 $ups = new UPS::Nut( NAME => "myups",
                      HOST => "somemachine.somewhere.com",
                      PORT => "3305",
                      USERNAME => "upsuser",
                      PASSWORD => "upspasswd",
                      TIMEOUT => 30,
                      DEBUG => 0,
                      DEBUGOUT => "/some/file/somewhere");
 if ($ups->Status() =~ /OB/) {
    print "Oh, no!  Power failure!\n";
    }

=head1 DESCRIPTION

This is an object-oriented (whoo!) interface between Perl and upsd from 
the Network UPS Tools package (http://www.exploits.org/nut/).  It only 
does the things that it can do talking to upsd.  It won't monitor your UPS 
continually - you'll have to write something that does that, like:

for (;;) {
  if ($ups->Status() =~ /OB/) { 
    # Ack!  There's a power failure!  Sure wish I had written some code to 
    # deal with that situation...
    }
  }

=head1 CONSTRUCTOR

Shown with defaults: new UPS::Nut( NAME => "default", 
                                   HOST => "localhost", 
                                   PORT => "3305", 
                                   USERNAME => "", 
                                   PASSWORD => "", 
                                   DEBUG => 0, 
                                   DEBUGOUT => "");
* NAME is the name of the UPS to monitor, as specified in ups.conf
* HOST is the host running upsd
* PORT is the port that upsd is running on
* USERNAME and PASSWORD are those specified in upsd.conf.  If these aren't 
  specified, then you will only have access to the level of privileges in 
  upsd.conf that do not require a password.  This is configured in 
  upsd.conf. 
* DEBUG turns on debugging output
* DEBUGOUT is de thing you do when the s*** hits the fan.  Actually, it's 
  the filename where you want debugging output to go.  If it's not 
  specified, debugging output comes to STDOUT. 

=head1 Methods

=head2 Methods for querying UPS status
 
Query(varname)
  returns value of the specified variable, if supported

BattPercent()
  returns % of battery left

LoadPercent()
  returns % of load, the UPS' available capacity

LineVoltage()
  returns line voltage, useful if your UPS doesn't do voltage regulation.

Status()
  returns status, one of "OL," "OB," or "LB," which are online (power OK), 
  on battery (power failure), or low battery, respectively.

Temperature()
  returns UPS temperature

=head2 Other methods

  These all operate on the UPS specified in the NAME argument to the 
  constructor.

Master()
  Use this to find out whether or not we have MASTER privileges for this 
  UPS. Returns 1 if we have MASTER privileges, returns 0 otherwise.

ListVars()
  Returns a list of all variables supported by the UPS.

ListInstCmds()
  Returns a list of all instant commands supported by the UPS.

InstCmd (command)
  Send an instant command to the UPS.  Returns undef if the command can't 
  be completed for whatever reason, otherwise returns 1.

FSD()
  Set the FSD (forced shutdown) flag for the UPS.  This means that we're 
  planning on shutting down the UPS very soon, so the attached load should 
  be shut down as well.  Returns 1 on success, returns undef on failure 
  for any reason.  This cannot be unset, so don't set it unless you mean 
  it.

Error()
  why did the previous operation fail?  The answer is here.  It will 
  return a concise, well-written, and brilliantly insightful few words as 
  to why whatever you just did went bang.  I promise that this method will 
  never return "Error: This module doesn't like you.  Go away."

TimeLeft()
  at current load, how much time before battery is depleted.  This isn't 
  very accurate at loads other than 25% and 50%, (the data points that I 
  got from CyberPower Systems) but it will give you a number.

=head1 Unimplemented commands to UPSD

  These are things that are listed in "protocol.txt" in the Nut 
  distribution that I haven't implemented yet.  Consult "protocol.txt" (in 
  the Nut distribution, under the docs/ subdirectory)  to see what these 
  commands do.

  SET ENUM VARDESC LISTRW VARTYPE INSTCMDDESC 

=head1 Notes

  Unless the load is at or very near 25% or 50%, this isn't accurate.  
  According to Cyberpower, at 50% load, the battery will last 
  approximately 40 minutes at full charge.  at 25% load, the 
  battery will last approximately 100 minutes at full charge.  At loads 
  higher than 50%, I'm told that the bettery life decreases 
  "exponentially."  So I drew a line, connecting the two points, which 
  is described by the function Battery life (minutes) = (-2.4 * Load 
  Percentage) + 160.  The accuracy will improve as I get more data 
  points.

=head1 AUTHOR

  Kit Peters 
  kpeters@iname.com
  http://www.awod.com/staff/kpeters/perl/

=head1 CREDITS

Developed with the kind support of A World Of Difference, Inc. 
<http://www.awod.com/>

Many thanks to Ryan Jessen <rjessen@cyberpowersystems.com> at CyberPower 
Systems for much-needed assistance.

=head1 LICENSE

This module is distributed under the same license as Perl itself.

=cut

1;
__END__

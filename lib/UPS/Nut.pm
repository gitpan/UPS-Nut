# UPS::Nut - a class to talk to a UPS via the Network Utility Tools upsd.
# Author - Kit Peters <perl@clownswilleatyou.com>

# ### changelog: made debug messages slightly more descriptive, improved
# ### changelog: comments in code
# ### changelog: removed timeleft function.  I may put a new timeleft 
# ### changelog: function in 0.04, or I may just let people do a request 
# ### changelog: for the RUNTIME var.

package UPS::Nut;
use strict;
use Carp;
use FileHandle;
use IO::Socket;

# The following globals dictate whether the accessors and instant-command
# functions are created.
# ### changelog: accessor functions for all supported vars added by 
# ### changelog: Wayne Wylupski

my $EXPAND_VARS = 0;	# UPS vars will have accessor functions created
my $EXPAND_INSTCMDS = 0;	# Instant commands will have functions created

BEGIN {
    use Exporter ();
    use vars qw ($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
    $VERSION     = 0.03; # $Id$
    @ISA         = qw(Exporter IO::Socket::INET);
    @EXPORT      = qw();
    @EXPORT_OK   = qw($EXPAND_VARS $EXPAND_INSTCMDS);
    %EXPORT_TAGS = ();
}

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my %arg = @_; # hash of arguments
  my $self = {};	# _initialize will fill it later
  bless $self, $class;
  unless ($self->_initialize(%arg)) { # can't initialize
    carp "Can't initialize: $self->{err}";
    return undef;
  }
  return $self;
}



# accessor functions.  Return a value if successful, return undef 
# otherwise.

sub BattPercent { # get battery percentage
  my $self = shift;
  my $var = "BATTPCT";
  return $self->Request($var);
}

sub LoadPercent { # get load percentage
  my $self = shift;
  my $var = "LOADPCT"; 
  return $self->Request($var);
}

sub LineVoltage { # get line voltage
  my $self = shift;
  my $var = "UTILITY";
  return $self->Request($var);
}  

sub Status { # get status of UPS
  my $self = shift;
  my $var = "STATUS";
  return $self->Request($var);
}

sub Temperature { # get the internal temperature of UPS
  my $self = shift;
  my $var = "UPSTEMP";
  return $self->Request($var);
}

# control functions: they control our relationship to upsd, and send 
# commands to upsd.

sub Login { # login to upsd, so that it won't shutdown unless we say we're 
            # ok.  This should only be used if you're actually connected 
            # to the ups that upsd is monitoring.

# ### changelog: modified login logic a bit.  Now it doesn't check to see 
# ### changelog: if we got OK, ERR, or something else from upsd.  It 
# ### changelog: simply checks for a response beginning with OK from upsd.  
# ### changelog: Anything else is an error.
  my $self = shift; # myself
  my $user = shift; # username
  my $pass = shift; # password
  my $srvsock = $self->{srvsock};
  my $errmsg; # error message, sent to _debug and $self->{err}
  my $ans; # scalar to hold responses from upsd

# only attempt login if username and password given
  if ((defined $user) && (defined $pass)) {

    print $srvsock "USERNAME $user\n"; # send username
    $self->_debug("Sent USERNAME $user to upsd.");
    chomp($ans = <$srvsock>);
    $self->_debug("Received $ans from upsd.");
    
    if ($ans =~ /^OK/) { # username OK, send password

      print $srvsock "PASSWORD $pass\n";
      $self->_debug("Sent PASSWORD $pass to upsd.");
      chomp ($ans = <$srvsock>);
      $self->_debug("Received $ans from upsd.");

      if ($ans =~ /^OK/) { # password OK, attempt to login

        print $srvsock "LOGIN $self->{name}\n"; 
        $self->_debug("Sent LOGIN $self->{name} to upsd.");

# ### changelog: 8/3/2002 - KP - modified login to send ups name w/LOGIN 
# ### changelog: command

        chomp ($ans = <$srvsock>); 
        $self->_debug("Received $ans from upsd.");
        if ($ans =~ /^OK/) { # Login successful. 
          $self->_debug("LOGIN successful.");
          return 1;
        }
      } 
    }
  }
  $errmsg = "LOGIN failed.  Last message from upsd: $ans";
  $self->_debug($errmsg);
  $self->{err} = $errmsg;
  return undef; 
}

sub Logout { # logout of upsd
  my $self = shift;
  my $srvsock = $self->{srvsock};
  if ($self->{srvsock}) { # are we still connected to upsd?
    print $srvsock ( "LOGOUT\n" );
    $self->_debug("Sent LOGOUT to upsd");  
    chomp (my $ans = <$srvsock>);
    $self->_debug("Received \"$ans\" from upsd");
    close ($srvsock);
  }
}

# internal functions.  These are only used by UPS::Nut internally, so 
# please don't use them otherwise.  If you really think an internal 
# function should be externalized, let me know.

sub _initialize { 
  my $self = shift;
  my %arg = @_;
  my $host = $arg{HOST}     || 'localhost'; # Host running master upsd
  my $port = $arg{PORT}     || '3493'; # 3493 is IANA assigned port for NUT
  my $proto = $arg{PROTO}   || 'tcp'; # use tcp unless user tells us to
  my $user = $arg{USERNAME} || undef; # username passed to upsd
  my $pass = $arg{PASSWORD} || undef; # password passed to upsd
  my $login = $arg{LOGIN}   || 0; # login to upsd on init?

  $self->{name} = $arg{NAME} || 'default'; # UPS name in etc/ups.conf on $host
  $self->{timeout} = $arg{TIMEOUT} || 30; # timeout
  $self->{debug} = $arg{DEBUG} || 0; # debugging?
  $self->{debugout} = $arg{DEBUGOUT} || undef; # where to send debug messages

  my $srvsock = $self->{srvsock} = # establish connection to upsd
    IO::Socket::INET->new(
      PeerAddr => $host, 
      PeerPort => $port,
      Proto    => $proto
    );

  my $ans; # response from upsd to various and sundry commands.  This gets 
           # reused a lot, but I don't think it's getting clobbered 
           # unnecessarily.  

  if (!$self->{srvsock}) { # can't connect
    $self->{err} = "Unable to connect via $proto to $host:$port: $!"; 
    return undef;
  }

  if ($login) { # attempt login to upsd if that option is specified
    if ($self->Login($user, $pass)) { 
      $self->_debug("Logged in successfully to upsd");
    }
    else { 
      $self->_debug("Login to upsd failed: $self->{err}");
      carp "Login to upsd failed: $self->{err}";
    }
  }

  $self->{vars} = $self->ListVars();  # get list of supported vars once,
                                  # so we know what we can and can't do.

  if ( $arg{EXPAND_VARS} || $UPS::Nut::EXPAND_VARS ) {
    $self->_expand_vars(); # create accessor functions for vars
  }

  if ( $arg{EXPAND_INSTCMDS} || $UPS::Nut::EXPAND_INSTCMDS ) {
    $self->_expand_instcmds(); # create accessor functions for instcmds
  }

  return 1; # initialization successful.
}

sub _expand_vars
{
# The following builds VARS accesser routines.
# This uses closures:  modified from Wall, et al: PROGRAMMING PERL 3rd Edition
# ### changelog: accessor functions for all supported vars added by Wayne 
# ### changelog: Wylupski

    my $self = shift;
    my @vars = split( / /, $self->{vars} );
    my $dummy;

# Wayne had some error checking code here, but the code duplicated that 
# in ListVars, so I've removed it. - KP - 8/4/2002

# not having "@<upsname>" in LISTVARS is acceptable behavior.  Removed 
# that section of Wayne's code that checked for "@<upsname>" - KP - 
# 8/4/2002

    if ($vars[0] =~ m/@/ ) { shift @vars } # throw away $vars[0] if it's
                                           # of the form "@<upsname>"

    for my $field ( @vars )
    {
        no strict "refs";
        *$field = sub {
            my $self = shift;
            if ( @_ )
            {
                return $self->Set( $field, shift );
            }
            else
            {
                return $self->Request( $field );
            }
        }
    }
}

# ### changelog: Added functions to directly call all supported instant 
# ### commands.  Added by Wayne Wylupski 
sub _expand_instcmds
{
    my $self = shift;
    my $instcmdstring = $self->ListInstCmds(); # get it in a string for debug
    my @instcmds = split / /, $instcmdstring;

# Wayne had error checking code here that was duplicated in 
# ListInstCmds().  Removed that section of his code.  KP - 8/4/2002

    for my $field ( @instcmds )
    {
        no strict "refs";
        *$field = sub {
            my $self = shift;
            $self->InstCmd($field);
        }
    }
}

sub Request { # request a variable from the UPS
  my $self = shift;
  my $srvsock = $self->{srvsock};
# ### changelog: 8/3/2002 - KP - Request() now returns undef if not
# ### changelog: connected to upsd via $srvsock 
  unless ($srvsock) {
    $self->{err} = "Not connected to upsd!";
    return undef;
  }
# work on error handling
  my $var = shift;
  unless ($self->{vars} =~ /$var/i) {
    $self->{err} = "Variable $var not supported by UPS $self->{name}\n";  
    return undef;
  }

  my $req = "REQ $var@" . $self->{name}; # build request
  my $null; # place to stick unwanted parts of a split()

  print $srvsock "$req\n"; # send request
  $self->_debug("sent request for $var \"$req\"");
  my $ans;
  eval { # this sets up the timeout for response from upsd
      local $SIG{'ALRM'} = sub { die "alarm clock reset" };
      alarm($self->{timeout});
      chomp ($ans = <$srvsock>);
      alarm(0);
  };
  alarm(0);
  if ($@ && $@ !~ /alarm clock reset/ ) # timed out
  # ### added by Wayne Wylupski
  {
      $self->{err} = "Connection timed out after $self->{timeout} secs.";
      return undef;
  };
  $self->_debug("received answer \"$ans\"");
  if ($ans =~ /^ERR/) {
    $self->{err} = "Error: $ans.  Requested $var.";
    return undef;
  }
  elsif ($ans =~ /^ANS/) {
    my $checkvar; # to make sure the var we asked for is the var we got.
    my $retval; # returned value for requested VAR
    ($null, $checkvar, $retval) = split ' ', $ans, 3; 
        # get checkvar and retval from the answer
    ($checkvar, $null) = split /@/, $checkvar, 2; # throw away "@<upsname>"
    if ($checkvar ne $var) { # did not get expected var
      $self->{err} = "requested $var, received $checkvar";
      return undef;  
    }
    return $retval; # return the requested value
  }
  else { # unrecognized response
    $self->{err} = "Unrecognized response from upsd: $ans";
    return undef;
  }
}   

sub Set() {
  my $self = shift;
  my $srvsock = $self->{srvsock};
# work on error handling
  my $var = shift;
  my $value = shift;
  unless ($self->{vars} =~ /$var/i) {
    $self->{err} = "Variable $var not supported by UPS $self->{name}\n";  
    return undef;
  }

  my $req = "SET $var@" . $self->{name} . " " . $value; # build request
  my $null; # place to stick unwanted parts of a split()

  print $srvsock "$req\n"; # send request
  $self->_debug("sending request \"$req\"");
  my $ans;
  eval { # timeout timer
      local $SIG{'ALRM'} = sub { die "alarm clock reset" };
      alarm($self->{timeout});
      chomp ($ans = <$srvsock>);
      alarm(0);
  };
  alarm(0);
  if ($@ && $@ !~ /alarm clock reset/ ) # timed out
  {
      $self->{err} = "Connection timed out after $self->{timeout} secs.";
      return undef;
  };
  $self->_debug("received answer \"$ans\"");
  if ($ans =~ /^ERR/) {
    $self->{err} = "Error: $ans";
    return undef;
  }
  elsif ($ans =~ /^ANS/) {
# this only checks to see if we got the var we asked for.  modify this to 
# check to see if we got the requested value for the var.
    my $checkvar; # to make sure the var we asked for is the var we got.
    my $retval; # return value
    ($null, $checkvar, $retval) = split ' ', $ans, 3; # get var and value
    ($checkvar, $null) = split /@/, $checkvar, 2; # throw away "@<upsname>"
    if ($checkvar ne $var) { # did not get the var we asked for
      $self->{err} = "requested $var, received $checkvar";
      return undef;  
    }
    if ($retval ne $value) {
      $self->{err} = "Requested to set $var to $value, but $var set to$retval";    
      return undef;
    }
    return $retval; # for compatibility with earlier versions of Nut.pm
  }
  else { # unrecognized response
    $self->{err} = "Unrecognized response from upsd: $ans";
    return undef;
  }
}   

sub FSD { # set forced shutdown flag
  my $self = shift;
  my $srvsock = $self->{srvsock};

  my $req = "FSD " . $self->{name}; # build request
  print $srvsock "$req\n"; # send request
  $self->_debug ("Sent \"$req\" to upsd.");
  chomp (my $ans = <$srvsock>);
  $self->_debug ("Received \"$ans\" from upsd.");
  if ($ans =~ /^ERR/) { # can't set forced shutdown flag
    $self->{err} = "Can't set FSD flag.  Upsd reports: $ans";
    return undef;
  }
  elsif ($ans =~ /^OK FSD-SET/) { # forced shutdown flag set
    $self->_debug("FSD flag set successfully.");
    return 1;
  }
  else {
    $self->{err} = "Unrecognized response from upsd: $ans";
    return undef;
  }
}

sub InstCmd { # send instant command to ups
  my $self = shift;
  my $srvsock = $self->{srvsock};

  chomp (my $cmd = shift);
  unless ($self->{instcmds} =~ /$cmd/i) { # is the command supported
    $self->{err} = "Instant command $cmd not supported by UPS$self->{name}.";
    return undef;
  }
  my $req = "INSTCMD" . $cmd . "@" . $self->{name};
  print $srvsock "$req\n"; # send instant command
  chomp (my $ans = <$srvsock>);
  if ($ans =~ /^ERR/) { # error reported from upsd
    $self->{err} = "Can't send instant command $cmd. Reason: $ans";
    return undef;
  }
  elsif ($ans =~ /^OK/) { # command successful
    $self->_debug("Instant command $cmd sent successfully.");
    return 1;
  }
  else { # unrecognized response
    $self->{err} = "Can't send instant command $cmd. Unrecognized response from upsd: $ans";
    return undef;
  }
}

sub DESTROY { # destructor, all it does is call Logout
  my $self = shift;
  $self->_debug("Object destroyed.");
  $self->Logout();
}

sub _debug { # print debug messages to stdout or file
  my $self = shift;
  if ($self->{debug}) {
    chomp (my $msg = shift);
    my $out; # filehandle for output
    if ($self->{debugout}) { # if filename is given, use that
      $out = new FileHandle ($self->{debugout}, ">>") or warn "Error: $!";
    } 
    if ($out) { # if out was set to a filehandle, create nifty timestamp
      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
      $year = sprintf("%02d", $year % 100); # Y2.1K compliant, even!
      my $timestamp = join '/', ($mon + 1), $mday, $year; # today
      $timestamp .= " ";
      $timestamp .= join ':', $hour, $min, $sec;
      print $out "$timestamp $msg\n";
    }
    else { print "DEBUG: $msg\n"; } # otherwise, print to stdout
  }
}

sub Error { # what was the last thing that went bang?
  my $self = shift;
  if ($self->{err}) { return $self->{err}; }
  else { return "No error explanation available."; }
}

sub ListVars { # get list of supported variables
  my $self = shift;
  my $srvsock = $self->{srvsock};

  my $req = "LISTVARS " . $self->{name}; # build request
  my $availvars; # available variables
  print $srvsock "$req\n";
  $self->_debug("Sent \"$req\" to upsd");
  chomp ($availvars = <$srvsock>);
  $self->_debug("Received \"$availvars\" from upsd.");
  unless ($availvars =~ /^VARS/) {
    $self->{err} = "Can't get var list.  Upsd response: $availvars";
    return undef;
  }
  return $availvars;
}

sub ListRW { # get list of supported read/writeable variables
  my $self = shift;
  my $srvsock = $self->{srvsock};

  my $req = "LISTRW " . $self->{name};
  my $availvars;
  $self->_debug("Sending \"$req\" to upsd");
  print $srvsock "$req\n";
  chomp ($availvars = <$srvsock>);
  $self->_debug("Received \"$availvars\" from upsd.");
  unless ($availvars =~ /^RW/) {
    $self->{err} = "Can't get var list.  Upsd response: $availvars";
    return undef;
  }
  return $availvars;
}

sub Master { # check for MASTER level access
  my $self = shift;
  my $srvsock = $self->{srvsock}; # socket for communicating w/ upsd

  my $req = "MASTER " . $self->{name}; # build request
  $self->_debug ("Sending \"$req\" to upsd.");
  print $srvsock "$req\n"; # send request
  chomp (my $ans = <$srvsock>);
  $self->_debug ("Received \"$ans\" from upsd.");
  if ($ans =~ /^OK/) { # access granted
    $self->_debug("MASTER level access granted.  Upsd reports: $ans");
    return 1;
  }
  else { # access denied, or unrecognized reponse
    $self->{err} = "MASTER level access denied.  Upsd responded: $ans";
# ### changelog: 8/3/2002 - KP - Master() returns undef rather than 0 on 
# ### failure.  this makes it consistent with other methods
    return undef;
  }
}

sub ListInstCmds { # check for available instant commands
  my $self = shift;
  my $srvsock = $self->{srvsock}; # socket for communicating w/ upsd

  my $req = "LISTINSTCMD " . $self->{name}; # build request
  $self->_debug("Sending \"$req\" to upsd.");
  print $srvsock "$req\n"; # send request
  chomp (my $ans = <$srvsock>);
  $self->_debug("Received \"$ans\" from upsd.");
  if ($ans =~ /^INSTCMDS/) { # got instant command list
    return $ans;
  }
  else { # error, or unrecognized response
    $self->{err} = "Upsd responded: $ans";
    return undef;
  }
}

=head1 NAME

Nut - a module to talk to a UPS via NUT (Network UPS Tools) upsd

=head1 SYNOPSIS

 use UPS::Nut;

 $ups = new UPS::Nut( NAME => "myups",
                      HOST => "somemachine.somewhere.com",
                      PORT => "3493",
                      USERNAME => "upsuser",
                      PASSWORD => "upspasswd",
                      TIMEOUT => 30,
                      DEBUG => 1,
                      DEBUGOUT => "/some/file/somewhere",
                      EXPAND_VARS => 1,
                      EXPAND_INSTCMDS => 1,
                    );
 if ($ups->Status() =~ /OB/) {
    print "Oh, no!  Power failure!\n";
 }

=head1 DESCRIPTION

This is an object-oriented (whoo!) interface between Perl and upsd from 
the Network UPS Tools package (http://www.exploits.org/nut/).  Note that 
it only talks to upsd for you in a Perl-ish way.  It doesn't continually 
monitor the UPS.

=head1 CONSTRUCTOR

Shown with defaults: new UPS::Nut( NAME => "default", 
                                   HOST => "localhost", 
                                   PORT => "3493", 
                                   USERNAME => "", 
                                   PASSWORD => "", 
                                   DEBUG => 0, 
                                   DEBUGOUT => "",
                                   EXPAND_VARS => 0,
                                   EXPAND_INSTCMDS => 0,
                                 );
* NAME is the name of the UPS to monitor, as specified in ups.conf
* HOST is the host running upsd
* PORT is the port that upsd is running on
* USERNAME and PASSWORD are those that you use to login to upsd.  This 
  gives you the right to do certain things, as specified in upsd.conf.
* DEBUG turns on debugging output, set to 1 or 0
* DEBUGOUT is de thing you do when the s*** hits the fan.  Actually, it's 
  the filename where you want debugging output to go.  If it's not 
  specified, debugging output comes to standard output.
* EXPAND_VARS automatically creates accessor functions for all
  the UPS variables.  For instance, $ups->MFR and $ups->UPSIDENT( "my UPS" );
  would end up being legitimate calls.  Set to 1 or 0
* EXPAND_INSTCMDS automatically creates functions for the instant
  commands.  For instance $ups->SHUTDOWN would be a legitimate call.  You
  would still need the proper permissions to run the command.  Set to 1 or 
  0

=head1 Methods

=head2 Methods for querying UPS status
 
Request(varname)
  returns value of the specified variable.  Returns undef if variable 
  unsupported.

Set(varname, value)
  sets the value of the specified variable.  Returns undef if variable 
  unsupported, or if variable cannot be set for some other reason.

BattPercent()
  returns percentage of battery left.  Returns undef if we can't get 
  battery percentage for some reason.

LoadPercent()
  returns percentage of the load on the UPS.  Returns undef if load 
  percentage is unavailable.

LineVoltage()
  returns input line (e.g. the outlet) voltage.  Returns undef if line 
  voltage is unavailable.

Status()
  returns UPS status, one of OL or OB.  OL or OB may be followed by LB, 
  which signifies low battery state.  OL or OB may also be followed by 
  FSD, which denotes that the forced shutdown state 
  ( see UPS::Nut->FSD() ) has been set on upsd.  Returns undef if status 
  unavailable.  

Temperature()
  returns UPS internal temperature.  Returns undef if internal temperature 
  unavailable.

=head2 Other methods

  These all operate on the UPS specified in the NAME argument to the 
  constructor.

Master()
  Use this to find out whether or not we have MASTER privileges for this 
  UPS. Returns 1 if we have MASTER privileges, returns 0 otherwise.

ListVars()
  Returns a list of all read-only variables supported by the UPS.  Returns 
  undef if these are unavailable.

ListRW()
  Returns a list of all read/writeable variables supported by the UPS.  
  Returns undef if these are unavailable.

ListInstCmds()
  Returns a list of all instant commands supported by the UPS.  Returns 
  undef if these are unavailable.  

InstCmd (command)
  Send an instant command to the UPS.  Returns 1 on success.  Returns 
  undef if the command can't be completed.

FSD()
  Set the FSD (forced shutdown) flag for the UPS.  This means that we're 
  planning on shutting down the UPS very soon, so the attached load should 
  be shut down as well.  Returns 1 on success, returns undef on failure. 
  This cannot be unset, so don't set it unless you mean it.

Error()
  why did the previous operation fail?  The answer is here.  It will 
  return a concise, well-written, and brilliantly insightful few words as 
  to why whatever you just did went bang.  

=head1 Unimplemented commands to UPSD

  These are things that are listed in "protocol.txt" in the Nut 
  distribution that I haven't implemented yet.  Consult "protocol.txt" (in 
  the Nut distribution, under the docs/ subdirectory)  to see what these 
  commands do.

  ENUM VARDESC VARTYPE INSTCMDDESC 

=head1 AUTHOR

  Kit Peters 
  perl@clownswilleatyou.com
  http://www.awod.com/staff/kpeters/perl/

=head1 CREDITS

Developed with the kind support of A World Of Difference, Inc. 
<http://www.awod.com/>

Many thanks to Ryan Jessen <rjessen@cyberpowersystems.com> at CyberPower 
Systems for much-needed assistance.

Thanks to Wayne Wylupski <wayne@connact.com> for the code to make 
accessor methods for all supported vars. 

=head1 LICENSE

This module is distributed under the same license as Perl itself.

=cut

1;
__END__


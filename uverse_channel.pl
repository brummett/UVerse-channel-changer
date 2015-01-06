#!/usr/bin/perl
use strict;
use warnings;

# usage:  uverse_channel.pl <ir_xmit_number> <channel_number>
#
# This is the latest iteration of trying to keep the Motorola 1200
# boxes awake when it's time to record something.  So far, I've tried:
# 1) Pressing the exit-to-tv button every 2 hours
# 2) asking the mythconverg DB what channel we're on ahd inputting that
#    channel right back in
# 3) changing to channe 2 first, then back to whatever chnnel mythconverg
#    has
# 4) toggling power off/on
# 5) toggling the power off/on, then changing the channel

my $ir_xmit = $ARGV[0];
my $channel = $ARGV[1];

my $REMOTE_NAME = 'Motorola_VIP_1200';
our $LOCK_DIR = '/tmp/uverse_channel_change';
END { rmdir $LOCK_DIR }

# Redirect stdin/out to the mythtv log file
open(STDOUT, ">>/var/log/mythtv/mythbackend.log");
open(STDERR, ">>/var/log/mythtv/mythbackend.log");

main::log("Using transmit class $transmit_class");
get_lock();

main::log("$$: Switching to IR transmitter $ir_xmit");
`irsend SET_TRANSMITTERS $ir_xmit`;

main::log("$$: Changing to channel $channel");

Changer->wake_up;
Changer->change_channel($channel);

exit(0);

#####################################################3

# Put the program's name and time in the message
sub log {
    print scalar(localtime),
          ": $0: ",
          @_,
          "\n";
}

sub get_lock {
    my $worked = 0;
    main::log("Getting lock");
    while(1) {
        $worked = mkdir $LOCK_DIR;
        last if $worked;
        if ($! ne 'File exists') {
            die "Couldn't make lock directory $LOCK_DIR: $!";
        }
        main::do_sleep(0.5);
    }
}

sub do_sleep {
    my $duration = shift;

    select(undef,undef,undef, $duration);
}
        
package Changer;

sub send_button {
    my $class = shift;
    die "class $class didn't implement send_button";
}

sub wake_up {
    my $class = shift;
    die "class $class didn't implement wake_up";
}

sub delay_between_buttons {
    my $class = shift;
    die "class $class didn't implement wake_up";
}

sub split_channel_numbers {
    my $class = shift;
    my $channel = shift;

    my @numbers = split(//,$channel);

    while (@numbers < 4) {
        unshift @numbers, '0';
    }
    return @numbers;
}


sub change_channel {
    my $class = shift;
    my $channel = shift;

    my @numbers = $class->split_channel_numbers($channel);

    foreach my $number ( @numbers ) {
        $class->send_button($number);
        main::do_sleep($class->delay_between_buttons);
    }
}


sub delay_between_buttons { 0.5 }

sub wake_up {
    my $class = shift;

    $class->send_button('ok');
    # Wait fror it to wake up
    main::do_sleep($class->delay_between_buttons);
    main::do_sleep($class->delay_between_buttons);

    # One more time in case there's a message on screen
    $class->send_button('ok');
    main::do_sleep($class->delay_between_buttons);

    # exit-to-tv in case it's on the video-on-demand screen
    $class->send_button('exit');

    main::do_sleep($class->delay_between_buttons);
}

# Send a single button press to the stb
sub send_button {
    my $class = shift;
    my $button = shift;
    
    main::log("sending $button");
    `irsend SEND_ONCE $REMOTE_NAME $button`;
}


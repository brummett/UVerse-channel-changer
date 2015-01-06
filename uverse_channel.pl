#!/usr/bin/perl
use strict;
use warnings;

# usage:  uverse_channel.pl <tuner_number> <channel_number>
# where tuner_number gets used as part of the lircd and video
# device names - see the declaration of $IRSEND below.
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
#
# What we're doing here is based on the method at
# http://evuraan.blogspot.com/2008/01/how-to-ensure-set-top-box-stb-is.html
# Like the original, we take a short snippet of mpeg video, convert it
# to individual frames of jpeg files with ffmpeg, then convert those to
# ascii with jp2a.
# The difference here is that the Motorola's "off" mode is reall a screensaver
# with a pulsating black and blue screen with the message "Press OK to watch
# ATT Uverse" that moves around the screen, so we can't use a simple blank
# screen detection
# Instead, we look for 255 blue pixels among the top and bottom 3 rows in
# the jp2a "image".  And then not including the top 2 and bottom 2 lines,
# there must be more than 10 blank rows.  The algorithm is in analyze_jpg()
# below.

my $ir_xmit = $ARGV[0];
my $channel = $ARGV[1];

# number of seconds to wait between numbers when
# changing the channel
our $DELAY_BETWEEN_BUTTONS = 0.5;

# We assumme tuner 0 means use /dev/lircd0 and /dev/video0
# Later on we can put stuff in a config file or something
my $REMOTE_NAME = 'Motorola_VIP_1200';
our $IRSEND = "irsend -d /dev/lircd SEND_ONCE $REMOTE_NAME ";
our $LOCK_DIR = '/tmp/uverse_channel_change';
END { rmdir $LOCK_DIR }

# Redirect stdin/out to the mythtv log file
open(STDOUT, ">>/var/log/mythtv/mythbackend.log");
open(STDERR, ">>/var/log/mythtv/mythbackend.log");

&get_lock();

&log("$$: Switching to IR transmitter $ir_xmit");
`irsend -d /dev/lircd SET_TRANSMITTERS $ir_xmit`;

&log("$$: Changing to channel $channel");

&send_button('ok');
# Wait fror it to wake up
select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);
select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);

# One more time in case there's a message on screen
&send_button('ok');
select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);

&send_button('EXIT');
select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);

#if (&stb_is_off($tuner)) {
#    &send_button('power');
#    sleep 5;
#}

&change_channel($channel);
exit(0);

#####################################################3

sub get_lock {
    my $worked = 0;
    &log("Getting lock");
    while(1) {
        $worked = mkdir $LOCK_DIR;
        last if $worked;
        if ($! ne 'File exists') {
            die "Couldn't make lock directory $LOCK_DIR: $!";
        }
        select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);
    }
}
        

# Send a single button press to the stb
sub send_button {
    my $button = shift;
    
    our $IRSEND;

    &log("sending $button");
    `$IRSEND $button`;
}

# Change to the given channel number
sub change_channel {
    my $channel = shift;

    # Pad to make a 4-digit channel number
    my $channel_length = (length($channel));
    if ($channel_length < 4) {
        $channel = '0' x (4 - $channel_length) . $channel;
    }

    my @numbers = split(//,$channel);
    foreach my $number ( @numbers ) {
        &send_button($number);
        select(undef,undef,undef,$DELAY_BETWEEN_BUTTONS);
    }
}


# Put the program's name and time in the message
sub log {
    print scalar(localtime),
          ": $0: ",
          @_,
          "\n";
}

# Return true if it thinks the box is off
sub stb_is_off {
    my $tuner = shift;

    my $video_dir = "/tmp/cc-$$/";
    mkdir($video_dir);

    my $videodev = "/dev/video$tuner";
    my $video = "$video_dir/video.mpeg";

    unless (&get_video($videodev,$video)) {
        &log("Can't get video.  Maybe $videodev is busy?");
        return;
    }

    my @jpgs = &make_jpgs($video,$video_dir);

    my $is_on = 0;
    my $is_off = 0;
    foreach my $file ( @jpgs ) {
        if (&analyze_jpg($file)) {
            $is_off++;
        } else {
            $is_on++;
        }
    }

    if ($is_off != $is_on) {
        # Normal case - remove the files we created
        #&cleanup($video_dir);
    } else {
        # Keep these around for human analysis
        &log("for pid $$, some files detected as on, some as off");
    }

    &log("on score $is_on, off score $is_off");
    if ($is_off && !$is_on) {
        open(F,"> $video_dir/off");
        close(F);
        return 1;
    } else {
        open(F,"> $video_dir/on");
        close(F);
        return 0;
    }
}



sub cleanup {
    my $video_dir = shift;

    my @files = glob("$video_dir/*");
    foreach my $file ( @files ) {
        unlink($file);
    }

    rmdir $video_dir;
}
    

# Given a jpg file, return true if we think it's in screen-saver mode
# The screen saver has some blue bands at the top and bottom of the 
# screen that fade in and out, and a message about "Press OK" that 
# moves around the screen.
sub analyze_jpg {
    my($file) = @_;

    open(JP2A, "jp2a $file --invert --size=72x24 --color |");
    my @lines = <JP2A>;
    chomp(@lines);
    foreach (@lines) {
        # Boost the emphasis at the high end (actually low end because of --invert)
        s/W|N/M/g;
    }

    my ($chars,$colors) = &split_colors(@lines);

    my $total_rows = scalar(@$chars);
    my $total_columns = length($chars->[0]);

    # Find the number of blue pixels in the top and bottom 3 rows
    my $blue_score = 0;
    foreach my $row ( 0.. 2 , ($total_rows-3) .. ($total_rows-1)) {
        my @colors = split(//,$colors->[$row]);
        for (my $col = 0; $col < $total_columns; $col++) {
            if ($colors[$col] eq chr(34)) {
                $blue_score++;
            }
        }
    }
    &log("$file blue_score $blue_score");
    # Around 1 Juny 2009, they changed the screen saver screen so that there is only
    # different shades of blue, and no black, anymore.  I'm changing the algorithm 
    # so that it only checks the blue score now.  
    return $blue_score > 400;

    # Except for the top and bottom 2 rows, how many lines are blank all the way across?
    my $all_blank_string = "M" x $total_columns;
    my $blank_lines = 0;
    foreach my $row ( 2 .. ($total_rows - 3)) {
        if ($chars->[$row] eq $all_blank_string) {
            $blank_lines++;
        }
    }

    &log("        blank_lines $blank_lines");
    if ($blank_lines > 10) {
        # Found more than 10 blank rows
        return 1;
    } else {
        return;
    }
}
       

# Given a list of lines read from the textified jpg, 
# return two listrefs: one that's a list of chars on each line,
# one that's a list of colors for those chars
sub split_colors {
    my(@chars,@colors);

    my $current_color = 0;
    foreach my $line ( @_ ) {
        # It looks like jp2a in --color mode puts an escape sequence befor and after every char
        #my($code,$color,$char,$code2,$color2) = ($line =~ m/^(\e\[(\d+)m)(.)(\e\[(\d+)m)/);
        
        my($chars,$colors);
my $line_before;
        while($line) {
$line_before = $line;
            #unless ($line =~ s/^(\e\[(\d+)m)(.)(\e\[(\d+)m)// ) {
            if ($line =~ s/^\e\[(\d+)m//) {
                $current_color = $1;
            } else {
                $colors .= chr($current_color);
                $chars .= substr($line,0,1,'');
            }
        }
        push @chars, $chars;
        push @colors, $colors;
    }
    return (\@chars, \@colors);
}


sub get_video {
    my($videodev, $file) = @_;

    unless (open(VIDEO,"$videodev")) {
        &log("Can't open $videodev: $!");
        return;
    }

    unless (open(F,">$file")) {
        &log("Can't open $file for writing: $!");
        return;
    }

    my $bytes_to_read = 1024*64*3;  
    while($bytes_to_read > 0) {
        my $buf;
        my $read = read(VIDEO,$buf,1024);

        unless (defined($read)) {
            &log("Error reading from $videodev: $!");
            return;
        }
        print F $buf;
        $bytes_to_read -= $read;
    }
    close(VIDEO);
    close(F);
}

   
sub make_jpgs {
    my($video,$video_dir) = @_;

    `ffmpeg -i $video -f image2 -vcodec mjpeg $video_dir/frame-%d.jpeg 1>/dev/null 2>/dev/null`;
    return glob("$video_dir/*jpeg");
}

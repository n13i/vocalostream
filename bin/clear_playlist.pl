#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use YAML;
use DBD::SQLite;
use Encode;
use Audio::MPD;

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $mpd = Audio::MPD->new(
    hostname => $conf->{mpd}->{host},
    port => $conf->{mpd}->{port},
);

my @playlist = $mpd->playlist->as_items;
my $current = $mpd->song->id;
printf "MPD playing: %d\n", $current;

my @delete_ids = ();
foreach my $item (@playlist)
{
    printf "%d: %s\n", $item->id, $item->title;
    next if($item->id == $current);
    push(@delete_ids, $item->id);
    #print Dump($item);
}

print Dump(@delete_ids);
$mpd->playlist->deleteid(@delete_ids);

exit;


sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}


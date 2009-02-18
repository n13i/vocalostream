#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter;
use Encode;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $conf = load_config;

my $post = $ARGV[0] || die;

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

if($conf->{twitter}->{post_enable} == 1)
{
    $twit->update(encode('utf8', $post));
}

exit;


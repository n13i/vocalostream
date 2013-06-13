#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter::Lite::WithAPIv1_1;
use Encode;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $conf = load_config;

my $post = $ARGV[0] || die;
$post = decode('utf-8', $post);

my $twit = Net::Twitter::Lite::WithAPIv1_1->new(
    api_url => $conf->{twitter}->{api_url},
    upload_url => $conf->{twitter}->{upload_url},
    consumer_key => $conf->{twitter}->{consumer_key},
    consumer_secret => $conf->{twitter}->{consumer_secret},
);
$twit->access_token($conf->{twitter}->{access_token});
$twit->access_token_secret($conf->{twitter}->{access_token_secret});

if($conf->{twitter}->{post_enable} == 1)
{
    $twit->update($post);
}

exit;


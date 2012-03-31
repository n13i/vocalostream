#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use YAML;
use DBD::SQLite;
use WWW::NicoVideo::Download;
use HTTP::Cookies;
use URI::Escape;
use Web::Scraper;
use Encode;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';
binmode STDERR, ':encoding(utf8)';

my $mode = shift @ARGV || die;
my $query = shift @ARGV || die;
my $page = shift @ARGV || undef;

$query = decode('utf8', $query);

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {sqlite_unicode => 1}
);

my $cookie_jar = HTTP::Cookies->new(
    file => $conf->{dirs}->{data} . '/cookies.txt',
    autosave => 1
);
my $nv = WWW::NicoVideo::Download->new(
    email => $conf->{nicovideo}->{email},
    password => $conf->{nicovideo}->{password},
);
$nv->user_agent->cookie_jar($cookie_jar);
$nv->user_agent->agent($conf->{ua});
my $res = $nv->user_agent->post(
    'https://secure.nicovideo.jp/secure/login?site=niconico',
    {
        mail => $conf->{nicovideo}->{email},
        password => $conf->{nicovideo}->{password},
    });
if($res->is_error || $nv->is_logged_out($res))
{
    warn "login failed: " . $res->status_line;
    exit 1;
}

my $url = undef;
my $scraper = undef;
if($mode eq 'ranking')
{
    $url = sprintf 'http://www.nicovideo.jp/ranking/mylist/%s/vocaloid',
        $query;

    $scraper = scraper {
        process 'div.thumb_frm', 'videos[]' => scraper {
            process 'a.watch', 'url' => '@href', 'title' => 'TEXT';
        };
    };
}
elsif($mode eq 'tag')
{
    if(!defined($page) || $page == 1)
    {
        $url = sprintf 'http://www.nicovideo.jp/tag/%s?sort=f',
            uri_escape_utf8($query)
    }
    else
    {
        $url = sprintf 'http://www.nicovideo.jp/tag/%s?page=%d&sort=f',
            uri_escape_utf8($query), $page
    }

    $scraper = scraper {
        process 'div.thumb_col_1 table', 'videos[]' => scraper {
            process 'p.font16 a.watch', 'url' => '@href', 'title'  => 'TEXT';
        };
    };
}
else
{
    die;
}

$nv->user_agent->timeout(15);
print STDERR "loading $url\n";
$res = $nv->user_agent->get($url);
if($res->is_error)
{
    warn "search failed";
    print Dump($res);
    exit 1;
}
print Dump($res);

my $r = $scraper->scrape($res->decoded_content, 'http://www.nicovideo.jp/');
#print Dump($r->{videos});

foreach(@{$r->{videos}})
{
    if(defined($_->{url}))
    {
        printf "%s|%s\n", $_->{url}, $_->{title};
    }
}

exit;


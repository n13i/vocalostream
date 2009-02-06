#!/usr/bin/perl

# via http://www.bookshelf.jp/2ch/unix/1087225153.html#775

use Compress::Zlib;

$in = STDIN;

read $in,$header,8;

if ($header !~ /^CWS/)
{
    undef $/;
    $buffer = <$in>;
    $out = STDOUT;
    print $out $header;
    print $out $buffer;
    exit;
}

undef $/; # enable slurp mode
$buffer = <$in>;

#$buffer = compress($buffer) ;
$buffer = uncompress($buffer) ;
$header =~ s/^C/F/;

$out = STDOUT;
print $out $header;
print $out $buffer;


package VocaloidFM;

use strict;
use warnings;
use utf8;

use base qw(Exporter);
our @EXPORT = qw(load_config get_config logger);

use FindBin qw($Bin);
use YAML;
use DateTime;

my $instance;

BEGIN {
    $instance = bless {
        config => undef,
    }, __PACKAGE__;
}

# static
sub get_config
{
    return $instance->{config};
}

# static
sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;

    $instance->{config} = $conf;

    return $conf;
}

# static
sub logger
{
    my $domain = shift;
    my $format = shift;
    my @args = @_;

    my $conf = get_config;
    open FH, '>>:encoding(utf8)', $conf->{logfile};
    printf FH "[%s] %s: $format",
        DateTime->now(time_zone => $conf->{timezone})->strftime('%y/%m/%d %H:%M:%S'), $domain, @args;
    if($format !~ /\n$/)
    {
        print FH "\n";
    }
    close FH;
}

1;
__END__


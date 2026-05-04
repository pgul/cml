#!/usr/bin/env perl
#
# PSGI wrapper for cml.cgi.
#
# CGI::Compile compiles cml.cgi once into an in-process subroutine
# (perl interpreter + modules + script body stay loaded between
# requests). CGI::Emulate::PSGI runs that sub per request, capturing
# STDOUT and trapping exit() so the worker survives.
#
# Run via Starman; see psgi/cml.service.

use strict;
use warnings;

use CGI::Compile;
use CGI::Emulate::PSGI;

my $cgi_path = $ENV{CML_CGI} || '/home/cml/cgi-bin/cml.cgi';

my $cgi = CGI::Compile->compile($cgi_path);
my $inner = CGI::Emulate::PSGI->handler($cgi);

# nginx terminates the connection; honour X-Forwarded-For so that
# $ENV{REMOTE_ADDR} inside cml.cgi is the real client.
sub {
    my $env = shift;
    if (my $xff = $env->{HTTP_X_FORWARDED_FOR}) {
        ($env->{REMOTE_ADDR}) = split /\s*,\s*/, $xff;
    }
    $inner->($env);
};

use 5.008001;
use strict;
use warnings;


use inc::Module::Install 0.91;
use ExtUtils::Depends;

name 'Sub-Call-Tail';
all_from 'lib/Sub/Call/Tail.pm';

requires_external_cc;

requires 'parent';
configure_requires 'ExtUtils::Depends' => 0.302; #minimum version that works on Win32+gcc
build_requires 'B::Hooks::OP::Check::EntersubForCV';
test_requires 'Test::More';
test_requires 'Test::use::ok';

my $pkg = ExtUtils::Depends->new('Sub::Call::Tail' => 'B::Hooks::OP::Check::EntersubForCV');

makemaker_args(
    $pkg->get_makefile_vars,
    DL_FUNCS => { 'Sub::Call::Tail' => [] },
);

repository 'git://github.com/nothingmuch/Sub-Call-Tail.git';

ppport;

WriteAll;

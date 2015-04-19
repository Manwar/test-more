use strict;
use warnings;

use Test::More;
use Test::Stream::Tester;

use ok 'Test::Stream::Spec';
my $CLASS = 'Test::Stream::Spec';

BEGIN {
    package My::SpecTool;
    $INC{'My/SpecTool.pm'} = __FILE__;

    use Test::Stream qw/context/;
    use Test::Stream::Exporter;
    use Test::Stream::Spec qw/spec build_spec root_spec/;
    default_exports qw/workflow tests before_each/;
    Test::Stream::Exporter->cleanup;

    sub after_import {
        my $class = shift;
        my ($importer) = @_;
        Test::Stream::Spec->follow;
        root_spec($importer, 1);
    }

    sub workflow {
        my ($name, $code) = @_;
        my $ctx = context();
        my $caller = caller;
        my $parent = spec($caller);
        my $spec = $CLASS->new(context => $ctx->snapshot, name => $name, code => $code);
        $ctx = undef;

        build_spec($spec => $code);

        $parent->push_spec($spec);
    }

    sub tests {
        my ($name, $code) = @_;
        my $ctx = context();
        my $caller = caller;
        my $spec = spec($caller);
        $spec->push_subtest(@_);
    }

    sub before_each {
        my ($name, $code) = @_;
        my $ctx = context();
        my $caller = caller;
        my $spec = spec($caller);
        $spec->push_pre_test(@_);
    }

    1;
}

My::SpecTool->import();
sub tests;
sub workflow;
sub before_each;

use Test::Stream subtest_tap => 'delayed';

can_ok(__PACKAGE__, qw/workflow tests before_each/);

ok(1, "root");

tests basic => sub {
    ok(1, "basic inside");
};

workflow nested_outer => sub {
    ok(1, "inside inner");

    before_each pre => sub {
        ok(1, "inside pre");
    };

    workflow nested_inner => sub {
        ok(1, "inside deeper");

        tests inner_test_local => sub {
            ok(1, "inner test assertion local");
        };

        tests inner_test_fork => {iso => 1}, sub {
            ok(1, "inner test assertion fork");
        };
    };

    tests outer_test => sub {
        ok(1, "outer test assertion");
    };

};

done_testing;

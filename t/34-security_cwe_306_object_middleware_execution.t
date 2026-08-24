#!/usr/bin/env perl

use v5.38;
use experimental qw/class/;
use Test::More;

use PAGI::FastAPI;
use Future::AsyncAwait;

# Mock Object-based Middleware implementing wrap()
class MockObjectMiddleware {
    method wrap ($app) {
        return sub ($scope, $receive, $send) {
            $scope->{middleware_executed} = 1;
            return $app->($scope, $receive, $send);
        };
    }
}

my $app = PAGI::FastAPI->new();
$app->add_middleware(MockObjectMiddleware->new());

$app->get('/test', handler => async sub ($c) {
    return { ok => 1 };
});

# Test 1: Verify execution through to_app()
{
    my $handler = $app->to_app();
    my %scope   = ( type => 'http', path => '/test', method => 'GET' );
    my $res     = $handler->(\%scope, sub { Future->done() }, sub { Future->done() });
    $res->get if ref $res eq 'Future';

    ok($scope{middleware_executed}, 'Object middleware executed via to_app() pipeline (CWE-306 fix)');
}

# Test 2: Verify execution parity with to_pagi()
{
    my $handler = $app->to_pagi();
    my %scope   = ( type => 'http', path => '/test', method => 'GET' );
    my $res     = $handler->(\%scope, sub { Future->done() }, sub { Future->done() });
    $res->get if ref $res eq 'Future';

    ok($scope{middleware_executed}, 'Object middleware executed via to_pagi() pipeline');
}

done_testing;

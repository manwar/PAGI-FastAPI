#!/usr/bin/env perl

use v5.38;
use Test::More;
use Test::Fatal qw(exception);
use Future::AsyncAwait;

use PAGI::FastAPI;
use PAGI::Test::Client;

# A form page that hands over the token, and an endpoint to post to.
sub csrf_app ($app) {
    $app->get('/form', handler => async sub ($c) {
        return $c->html($c->csrf_token() // '');
    });
    $app->post('/submit', handler => async sub ($c) { return { status => 'ok' } });
    return $app;
}

subtest 'enable_csrf() needs no secret' => sub {
    my $app = PAGI::FastAPI->new();
    $app->add_middleware('PAGI::Middleware::Session');
    is(exception { $app->enable_csrf() }, undef, 'enable_csrf() with no secret anywhere');
    csrf_app($app);

    my $client = PAGI::Test::Client->new(app => $app->to_pagi);
    $client->get('/form');
    my $token = $client->cookies->{csrf_token};
    ok($token, 'the csrf_token cookie is issued');
    is($client->post('/submit', headers => { 'x-csrf-token' => $token })->status, 200,
        'a matching header passes');
    is($client->post('/submit')->status, 403, 'no header is refused');
};

subtest 'the app-level secret no longer reaches enable_csrf()' => sub {
    my $app = PAGI::FastAPI->new(secret => 'app-level-secret-12345');
    is(exception { $app->enable_csrf() }, undef, 'enable_csrf() lives with new(secret => ...)');
};

subtest 'enable_csrf(secret => ...) dies' => sub {
    my $app = PAGI::FastAPI->new();
    like(
        exception { $app->enable_csrf(secret => 'call-level-secret') },
        qr/CSRF no longer takes a secret/,
        'with PAGI::Middleware::CSRF\'s message',
    );
};

subtest 'enable_csrf(session => 1) keeps the token in the session' => sub {
    my $app = PAGI::FastAPI->new();
    $app->add_middleware('PAGI::Middleware::Session');
    $app->enable_csrf(session => 1);
    csrf_app($app);

    my $client = PAGI::Test::Client->new(app => $app->to_pagi);
    my $token = $client->get('/form')->text;
    like($token, qr/\A[0-9a-f]{64}\z/, 'the page carries the token');
    ok(!$client->cookies->{csrf_token}, 'no csrf_token cookie is set');
    is($client->post('/submit', headers => { 'x-csrf-token' => $token })->status, 200,
        'the page token passes');
};

done_testing;

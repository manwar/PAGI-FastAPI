#!/usr/bin/env perl

use v5.38;
use Test::More;
use Test::Fatal qw(exception);
use Future;
use Future::AsyncAwait;
use JSON::PP qw(decode_json);
use PAGI::FastAPI;

sub run_request ($pagi_app, %req) {
    my ($sent_start, $sent_body);
    my $recv = async sub { return { type => 'http.request', body => $req{body}, more_body => 0 } };
    my $send = async sub ($event) {
        $sent_start = $event if $event->{type} eq 'http.response.start';
        $sent_body  = $event if $event->{type} eq 'http.response.body';
    };

    $pagi_app->(
        {
            type         => 'http',
            method       => $req{method} // 'GET',
            path         => $req{path},
            query_string => '',
            headers      => [],
        },
        $recv, $send,
    )->get;

    my $decoded = $sent_body->{body} && length $sent_body->{body}
    ? eval { decode_json($sent_body->{body}) }
    : undef;

    return ($sent_start->{status}, $decoded);
}

subtest 'a background task keeps running after the response is returned' => sub {
    my @log;
    my $app  = PAGI::FastAPI->new(title => 'Background Test');
    my $gate = Future->new;

    $app->get('/send', handler => async sub ($c) {
        $c->background(async sub {
            await $gate;
            push @log, 'background finished';
        });
        push @log, 'handler returned';
        return { status => 'queued' };
    });

    my ($status, $data) = run_request($app->to_app, path => '/send');

    is $status, 200, 'request succeeds immediately, without waiting for the background task';
    is $data->{status}, 'queued', 'handler response is unaffected';
    is_deeply \@log, ['handler returned'],
        'the background task is genuinely still pending -- the response did not wait for it';

    $gate->done(1);
    is_deeply \@log, ['handler returned', 'background finished'],
        'once its own await resolves, the background task completes on its own, after the response was already sent';
};

subtest 'background() validates its argument' => sub {
    my $app = PAGI::FastAPI->new(title => 'Background Validation Test');
    my $ctx = PAGI::FastAPI::Context->new();

    like(
        exception { $ctx->background(sub { 42 }) },
        qr/did not return a Future/,
        'a plain (non-async) sub that does not return a Future is rejected clearly',
    );

    like(
        exception { $ctx->background("not a coderef") },
        qr/expects a CODE reference/,
        'a non-coderef argument is rejected clearly',
    );
};

subtest 'a failing background task does not crash the request or the app' => sub {
    my $app = PAGI::FastAPI->new(title => 'Background Failure Test');

    $app->get('/risky', handler => async sub ($c) {
        $c->background(async sub { die "boom\n"; });
        return { status => 'ok' };
    });

    my ($status, $data);
    my $warned = 0;
    local $SIG{__WARN__} = sub { $warned++ if $_[0] =~ /background task failed/ };

    ($status, $data) = run_request($app->to_app, path => '/risky');

    is $status, 200, 'the request itself still succeeds even though the background task will fail';
    is $data->{status}, 'ok', 'response body is unaffected by the background failure';
};

subtest 'pending background tasks are drained on lifespan shutdown' => sub {
    my $app         = PAGI::FastAPI->new(title => 'Drain Test');
    my $slow_future = Future->new;
    my $completed   = 0;

    $app->get('/slow', handler => async sub ($c) {
        $c->background(async sub {
            await $slow_future;
            $completed = 1;
        });
        return { status => 'queued' };
    });

    my $pagi_app = $app->to_app;
    run_request($pagi_app, path => '/slow');

    is $completed, 0, 'the background task has not finished yet (still awaiting $slow_future)';

    # Drive lifespan shutdown; queue the "resolve the pending future" event
    # right after startup, so it fires while shutdown is waiting on it.
    my @lifespan_events = ({ type => 'lifespan.startup' }, { type => 'lifespan.shutdown' });
    my $idx  = 0;
    my $recv = async sub {
        my $event = $lifespan_events[$idx++];
        $slow_future->done(1) if $event->{type} eq 'lifespan.shutdown';
        return $event;
    };
    my @sent;
    my $send = async sub ($event) { push @sent, $event };

    $pagi_app->({ type => 'lifespan' }, $recv, $send)->get;

    is $completed, 1, 'shutdown waited for the still-pending background task to finish before completing';
    ok((grep { $_->{type} eq 'lifespan.shutdown.complete' } @sent), 'shutdown still completes cleanly afterward');
};

done_testing;

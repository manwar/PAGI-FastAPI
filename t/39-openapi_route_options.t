#!/usr/bin/env perl

use v5.38;
use Test::More;
use Test::Fatal qw(exception);

use PAGI::FastAPI;
use Future::AsyncAwait;
use Types::Standard qw(Int);
use JSON::PP qw(decode_json);

async sub request ($pagi_app, $path) {
    my @sent;
    my $scope   = { type => 'http', method => 'GET', path => $path, headers => [] };
    my $receive = async sub { return { type => 'http.disconnect' }; };
    my $send    = async sub ($event) { push @sent, $event; };
    await $pagi_app->($scope, $receive, $send);
    return \@sent;
}

subtest 'tags, summary, description, deprecated are threaded into the OpenAPI doc' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');

    $app->get('/widgets/{id}',
        tags        => ['Widgets'],
        summary     => 'Fetch one widget',
        description => 'Returns a single widget by its numeric ID.',
        deprecated  => 1,
        handler     => async sub ($c) { return {} },
    );

    my $events  = request($app->to_app, '/openapi.json')->get;
    my $openapi = decode_json($events->[1]{body});
    my $doc     = $openapi->{paths}{'/widgets/{id}'}{get};

    is_deeply $doc->{tags}, ['Widgets'], 'tags carried through verbatim';
    is $doc->{summary},       'Fetch one widget', 'custom summary overrides the "$method $path" default';
    is $doc->{description},   'Returns a single widget by its numeric ID.', 'description carried through';
    is $doc->{deprecated}, 1, 'deprecated flag is set (JSON boolean true)';
};

subtest 'summary falls back to "$method $path" exactly as before when omitted' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');
    $app->get('/plain', handler => async sub ($c) { return {} });

    my $events  = request($app->to_app, '/openapi.json')->get;
    my $openapi = decode_json($events->[1]{body});
    my $doc     = $openapi->{paths}{'/plain'}{get};

    is $doc->{summary}, 'GET /plain', 'unchanged default summary (backward compatibility)';
    ok !exists $doc->{tags},          'no tags key is added when not supplied';
    ok !exists $doc->{description},   'no description key is added when not supplied';
    ok !exists $doc->{deprecated},    'no deprecated key is added when not supplied';
};

subtest 'responses map extends the default 200/422 entries rather than replacing them' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');

    $app->post('/widgets',
        responses => {
            201 => { description => 'Widget created'        },
            409 => { description => 'Widget already exists' },
        },
        handler => async sub ($c) { return {} },
    );

    my $events    = request($app->to_app, '/openapi.json')->get;
    my $openapi   = decode_json($events->[1]{body});
    my $responses = $openapi->{paths}{'/widgets'}{post}{responses};

    ok exists $responses->{200},       'the default 200 entry is still present';
    ok exists $responses->{422},       'the default 422 entry is still present';
    is $responses->{201}{description}, 'Widget created', 'the new 201 entry was added';
    is $responses->{409}{description}, 'Widget already exists', 'the new 409 entry was added';
};

subtest 'a responses entry can override a default entry (e.g. customize the 200 description)' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');

    $app->get('/widgets/custom200',
        responses => { 200 => { description => 'A custom 200 description' } },
        handler   => async sub ($c) { return {} },
    );

    my $events  = request($app->to_app, '/openapi.json')->get;
    my $openapi = decode_json($events->[1]{body});
    my $responses = $openapi->{paths}{'/widgets/custom200'}{get}{responses};

    is $responses->{200}{description}, 'A custom 200 description', 'the default 200 description was overridden';
    ok exists $responses->{422}, 'the untouched 422 default entry survives an override of 200';
};

subtest 'malformed tags/responses options are rejected clearly at registration time' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');

    like(
        exception {
            $app->get('/bad1',
                tags    => 'Widgets',
                handler => async sub ($c) { return {} })
        },
        qr/'tags' must be an ArrayRef/,
        'a non-ArrayRef tags option dies clearly instead of silently corrupting the spec',
    );

    like(
        exception {
            $app->get('/bad2',
                responses => ['not', 'a', 'hash'],
                handler   => async sub ($c) { return {} })
        },
        qr/'responses' must be a HashRef/,
        'a non-HashRef responses option dies clearly',
    );
};

subtest 'existing query/path param documentation is completely unaffected' => sub {
    my $app = PAGI::FastAPI->new(title => 'Metadata Test');
    $app->get('/items/{id}',
        query   => { page => Int },
        handler => async sub ($c) { return {} });

    my $events  = request($app->to_app, '/openapi.json')->get;
    my $openapi = decode_json($events->[1]{body});
    my $doc     = $openapi->{paths}{'/items/{id}'}{get};

    ok((grep { $_->{name} eq 'id'   && $_->{in} eq 'path'  } @{ $doc->{parameters} }), 'path parameter doc unchanged');
    ok((grep { $_->{name} eq 'page' && $_->{in} eq 'query' } @{ $doc->{parameters} }), 'query parameter doc unchanged');
};

done_testing;

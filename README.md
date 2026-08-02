# PAGI::FastAPI

[![CPAN version](https://badge.fury.io/pl/PAGI-FastAPI.svg)](https://metacpan.org/pod/PAGI::FastAPI)

FastAPI-inspired asynchronous micro-framework for Perl built on the **PAGI** protocol with **Type::Tiny** validation and automatic **OpenAPI 3.1** / **Swagger UI** documentation.

## SYNOPSIS

```perl
use v5.36;
use PAGI::FastAPI;
use Types::Standard qw(Int Str);
use Future::AsyncAwait;

my $app = PAGI::FastAPI->new(
    title   => 'My Async API',
    version => '1.0.0',
);

# Async GET route with path parameter and query validation
$app->get('/items/{id}',
    query   => { limit => Int },
    handler => async sub ($c) {
        return {
            item_id => $c->param('id'),
            limit   => $c->param('limit'),
            status  => 'active',
        };
    }
);

# Async POST route with JSON body validation
$app->post('/items',
    body    => { name => Str, price => Int },
    handler => async sub ($c) {
        return {
            created => 1,
            name    => $c->body('name'),
            price   => $c->body('price'),
        };
    }
);

# Export conforming PAGI application closure
my $pagi_app =$app->to_app;

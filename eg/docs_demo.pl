#!/usr/bin/env perl

# Minimum Requirement
#
# PAGI::FastAPI v1.7.0 or above.
#
# Start the server
#
#   pagi-server docs_demo.pl
#
# Then open http://localhost:5000/docs for the Swagger UI (or
# http://localhost:5000/openapi.json for the raw document) and look at:
#
#   - Routes grouped under the "Widgets" tag
#
#   - Every response on every /widgets* route below has a "links" entry,
#     including the framework's default 422, the only "No links" left
#     in this demo is GET / itself, the HTML landing page you're reading
#     this from, which isn't a JSON API response there's anything useful
#     to chain a link off of.
#
#   - GET /widgets/{id}'s 200 response links to "ArchiveWidget"
#     (DELETE /widgets/{id}), with its "id" parameter pre-filled from the
#     response body via a runtime expression ($response.body#/id), so
#     clicking it in Swagger UI's "Try it out" already has the id filled
#     in.
#
#   - DELETE /widgets/{id} rendered with a strikethrough (deprecated),
#     and using an explicit, human-chosen operationId instead of the
#     auto-generated default, which is exactly what the other routes'
#     links reference it by.
#
# Or drive it directly:
#
#   curl -X POST http://localhost:5000/widgets \
#        -H "Content-Type: application/json" \
#        -d '{"name": "Camel Plushie"}'
#
#   curl http://localhost:5000/widgets/1
#
#   curl http://localhost:5000/openapi.json | less

use v5.38;
use Future::AsyncAwait;
use Types::Standard qw(Str);
use PAGI::FastAPI;

use FindBin qw($RealBin);
use File::Spec;

my $assets_dir = File::Spec->catdir($RealBin, 'assets');

my $app = PAGI::FastAPI->new(
    title   => 'PAGI::FastAPI OpenAPI Metadata Demo',
    version => '1.7.0',
    swagger_ui_css_url    => '/assets/swagger-ui.css',
    swagger_ui_bundle_url => '/assets/swagger-ui-bundle.js',
);

$app->get('/assets/swagger-ui.css', handler => async sub ($c) {
    return $c->file(File::Spec->catfile($assets_dir, 'swagger-ui.css'));
});

$app->get('/assets/swagger-ui-bundle.js', handler => async sub ($c) {
    return $c->file(File::Spec->catfile($assets_dir, 'swagger-ui-bundle.js'));
});

# Demo-only in-memory store, just enough for these routes to behave like
# a real (tiny) CRUD API rather than returning fixed stub data.
my %widgets;
my $next_id = 1;

# Every operationId referenced by a 'links' entry below, in one place, so
# it's obvious at a glance which routes they're expected to resolve
# against. Three of these are auto-derived by PAGI::FastAPI's
# _operation_id_for (method + path, lowercased and slugified); the fourth,
# ArchiveWidget, is the explicit 'operation_id' override given to
# DELETE /widgets/{id} further down, since "delete_widgets_id" would be a
# strange name for a route that archives rather than deletes.
use constant {
    OP_LIST_WIDGETS   => 'get_widgets',         # GET    /widgets
    OP_GET_WIDGET     => 'get_widgets_id',      # GET    /widgets/{id}
    OP_CREATE_WIDGET  => 'post_widgets',        # POST   /widgets
    OP_ARCHIVE_WIDGET => 'archiveWidgetLegacy', # DELETE /widgets/{id}
};

# Landing Page
my $html_content = do { local $/; <DATA> };
$app->get('/',
    handler => async sub ($c) { $c->html($html_content); },
);

# tags, summary, and a 'links' entry on its only response, pointing
# forward at the operation that makes the most sense from an empty (or
# non-empty) list: creating a new widget.
$app->get('/widgets',
    tags      => ['Widgets'],
    summary   => 'List all widgets',
    responses => {
        200 => {
            description => 'The current widgets',
            links       => {
                CreateWidget => {
                    operationId => OP_CREATE_WIDGET,
                    description => 'Create a new widget',
                },
            },
        },
        422 => {
            description => 'Invalid query parameters',
            links       => {
                CreateWidget => {
                    operationId => OP_CREATE_WIDGET,
                    description => 'Create a new widget instead',
                },
            },
        },
    },
    handler => async sub ($c) {
        return { widgets => [ values %widgets ] };
    }
);

# tags, summary, description, and links on BOTH its responses: the
# 200 links to archiving this same widget (id filled in automatically
# via the '$response.body#/id' runtime expression) and back to the full
# list; the 404 offers the same two "what next" options a human would
# actually want after a dead end.
$app->get('/widgets/{id}',
    tags        => ['Widgets'],
    summary     => 'Fetch one widget',
    description => 'Returns a single widget by its numeric ID.',
    responses   => {
        200 => {
            description => 'The requested widget',
            links       => {
                ArchiveWidget => {
                    operationId => OP_ARCHIVE_WIDGET,
                    parameters  => { id => '$response.body#/id' },
                    description => 'Archive (delete) this widget',
                },
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'Back to the full widget list',
                },
            },
        },
        404 => {
            description => 'No widget with that ID',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'Browse existing widgets instead',
                },
                CreateWidget => {
                    operationId => OP_CREATE_WIDGET,
                    description => 'Or create one with this ID in mind',
                },
            },
        },
        422 => {
            description => 'The ID was not a valid widget ID',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See a list of valid IDs',
                },
            },
        },
    },
    handler => async sub ($c) {
        my $widget = $widgets{ $c->param('id') };
        unless ($widget) {
            $c->status(404);
            return { detail => 'Widget not found' };
        }
        return $widget;
    }
);

# responses with 'links' entries on both the success and conflict case.
# The 201's GetCreatedWidget/ArchiveWidget links both use 'parameters' to
# map the runtime response's "id" field onto the target operation's "id"
# path parameter, exactly the same pattern GET /widgets/{id}'s own 200
# response uses above, since both responses return a widget with an "id".
$app->post('/widgets',
    tags        => ['Widgets'],
    summary     => 'Create a widget',
    description => 'Creates a new widget and returns its ID.',
    body        => { name => Str },
    responses   => {
        # Every route keeps the framework's default 200 entry unless it's
        # explicitly overridden, even one like this that never actually
        # returns a plain 200 (success here is 201). Overriding it for
        # accuracy, same as everything else in this file getting a links
        # entry instead of "No links".
        200 => {
            description => 'Not actually returned by this operation '.
                           '(success is 201); documented here only because '.
                           'every route keeps a default 200 entry unless '.
                           'overridden',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See existing widgets',
                },
            },
        },
        201 => {
            description => 'Widget created',
            links       => {
                GetCreatedWidget => {
                    operationId => OP_GET_WIDGET,
                    parameters  => { id => '$response.body#/id' },
                    description => 'Fetch the widget just created',
                },
                ArchiveWidget => {
                    operationId => OP_ARCHIVE_WIDGET,
                    parameters  => { id => '$response.body#/id' },
                    description => 'Changed your mind? Archive it again',
                },
            },
        },
        409 => {
            description => 'A widget with that name already exists',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See what already exists under that name',
                },
            },
        },
        422 => {
            description => 'Missing or invalid "name" field',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See a valid example',
                },
            },
        },
    },
    handler => async sub ($c) {
        my $name = $c->body('name');

        if (grep { $_->{name} eq $name } values %widgets) {
            $c->status(409);
            return { detail => "A widget named '$name' already exists" };
        }

        my $id = $next_id++;
        $widgets{$id} = { id => $id, name => $name };

        $c->status(201);
        return $widgets{$id};
    }
);

# deprecated, plus an explicit operation_id override (rather than the
# auto-derived "delete_widgets_id"), useful here since "delete" isn't
# really what this route does underneath; external tooling referencing
# this ID shouldn't have to care that it changed. This is the operationId
# every OP_ARCHIVE_WIDGET link above points at.
$app->delete('/widgets/{id}',
    tags         => ['Widgets'],
    summary      => 'Delete a widget (deprecated)',
    description  => 'Deprecated: widgets are archived, not deleted, use '
                   . 'PATCH /widgets/{id} with {"archived": true} instead. '
                   . 'Kept for backward compatibility only.',
    deprecated   => 1,
    operation_id => OP_ARCHIVE_WIDGET,
    responses    => {
        200 => {
            description => 'Widget archived',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See what is left',
                },
                CreateWidget => {
                    operationId => OP_CREATE_WIDGET,
                    description => 'Create a replacement',
                },
            },
        },
        422 => {
            description => 'The ID was not a valid widget ID',
            links       => {
                ListWidgets => {
                    operationId => OP_LIST_WIDGETS,
                    description => 'See a list of valid IDs',
                },
            },
        },
    },
    handler => async sub ($c) {
        delete $widgets{ $c->param('id') };
        return { status => 'deleted' };
    }
);

$app->to_app;

__DATA__
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PAGI::FastAPI OpenAPI Metadata</title>
    <style>
        body { font-family: sans-serif; margin: 2em; max-width: 720px; }
        h2 { margin-bottom: 0.2em; }
        .sub { color: #666; margin-top: 0; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 1.2em 1.5em; margin-bottom: 1.2em; }
        code { background: #f4f4f4; padding: 1px 5px; border-radius: 4px; }
        a.button { display: inline-block; padding: 8px 14px; font-size: 0.95em; background: #007bff; color: white; border-radius: 4px; text-decoration: none; margin-right: 0.6em; }
        ul { padding-left: 1.2em; }
        li { margin-bottom: 0.4em; }
    </style>
</head>
<body>
    <h2>OpenAPI Metadata</h2>
    <p class="sub">tags, summary, description, deprecated, responses, operation_id, and links, all documented on the routes below.</p>

    <div class="card">
        <p><a class="button" href="/docs" target="_blank">Open Swagger UI</a>
           <a class="button" href="/openapi.json" target="_blank">Raw /openapi.json</a></p>
        <p>What to look for once it's open:</p>
        <ul>
            <li><code>GET /widgets</code> and <code>GET /widgets/{id}</code>, grouped under the "Widgets" tag, with custom summaries.</li>
            <li>Every response on every <code>/widgets*</code> route below has a <code>links</code> entry, including the framework's default <code>422</code>, check the "Links" column on any response, not just one. (This landing page itself is the one deliberate exception: it's HTML, not JSON, so there's nothing to chain a link off of.)</li>
            <li><code>GET /widgets/{id}</code>'s <code>200</code> and <code>POST /widgets</code>'s <code>201</code> both link to <code>ArchiveWidget</code> with the widget's <code>id</code> pre-filled from the response body, try clicking through from either one in Swagger UI.</li>
            <li><code>DELETE /widgets/{id}</code>, rendered with a strikethrough (<code>deprecated =&gt; 1</code>), and uses an explicit <code>operation_id</code> (<code>archiveWidgetLegacy</code>) instead of the auto-derived default, that's the ID every link to it references.</li>
        </ul>
    </div>
</body>
</html>

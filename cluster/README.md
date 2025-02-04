# Cluster

## Getting Started

This module provides an executable for starting a demo cluster of nodes.
It is designed to remove all the overhead of setting up a configuration
and an environment and to _just work_, out-of-the-box. Minor configuration
adjustments are however possible via environment variables.

```
$> stack exec -- bcc-sl-cluster-demo
Cluster is starting (4 core(s), 1 relay(s), 1 edge(s))...
...core0 has no health-check API.
......system start:  1539179287
......address:       127.0.0.1:3000
......locked assets: -
...core1 has no health-check API.
......system start:  1539179287
......address:       127.0.0.1:3001
......locked assets: -
...core2 has no health-check API.
......system start:  1539179287
......address:       127.0.0.1:3002
......locked assets: -
...core3 has no health-check API.
......system start:  1539179287
......address:       127.0.0.1:3003
......locked assets: -
...relay has no health-check API.
......system start:  1539179287
......address:       127.0.0.1:3100
...edge OK!
......system start:  1539179287
......api address:   127.0.0.1:8090
......doc address:   127.0.0.1:8190
Cluster is (probably) ready!
```


## Configuring Nodes

_Almost anything_ from the normal CLI arguments of a node can be
configured via an ENV variable using an `UPPER_SNAKE_CASE` naming, correctly
prefixed with `DEMO_` with a few gotchas:

- Flags need an explicit boolean value

- There's no ENV vars mapping to (i.e. you can't configure):
    - `--db-path`
    - `--logger-config`
    - `--node-id`
    - `--tlsca`
    - `--tlscert`
    - `--tlskey`
    - `--topology`
    - `--keyfile`
  Those variables actually corresponds to artifacts or location handled by the
  cluster library. Messing up with one of those can break the whole cluster.

- There's an extra `LOG_SEVERITY` variable that can be set to `Debug`, `Info`
  and so forth to ajust logging severity for _all_ nodes.

- There's an extra `STATE_DIR` variable used to provide the working directory
  for all nodes. See the [State Directory](#state-directory) section here-below.

- There's an extra `SYSTEM_START_OFFSET` which can be used to tweak the system
  start offset such that nodes can all correctly boot.

- When it make senses, variable values are automatically incremented by the
  node index. For instance, if you provide `LISTEN=127.0.0.1:3000`, then
    - core0 will receive "127.0.0.1:3000"
    - core1 will receive "127.0.0.1:3001"
    - core2 will receive "127.0.0.1:3002"
    - etc.

  This is the case for:
    - `--listen`
    - `--node-api-address`
    - `--node-doc-address`

For instance, one can disable TLS client authentication doing:

```
$> DEMO_NO_CLIENT_AUTH=True stack exec -- bcc-sl-cluster-demo
```

### Relative FilePath

One can provide relative filepath as values for ENV vars. They are computed from
the root repository folder, so for instance, providing `./state-demo` will point
to the directory `$(git rev-parse --show-toplevel)/state-demo`.


### State Directory

By default, each node receives a temporary state directory from the system;
probably somewhere in `/tmp`. This location can always be overriden by
providing an extra `DEMO_STATE_DIR` variable with a custom location.

Note that, each default has been choosen in such way that they won't conflict
if all nodes were to share the same state directory :)

### Configuring Cluster

The `bcc-sl-cluster-demo` is actually a full-blown CLI with default arguments.

```
$> stack exec -- bcc-sl-cluster-demo --help
bcc-sl-cluster-demo

Spawn a demo cluster of nodes running bcc-sl, ready-to-use

Usage:
  bcc-sl-cluster-demo [options]
  bcc-sl-cluster-demo --help

Options:
  --cores=INT  Number of core nodes to start [default: 4]
  --relays=INT Number of relay nodes to start [default: 1]
  --edges=INT  Number of edge nodes to start [default: 1]
```

So, the components of the cluster may be tweaked by providing arguments to the CLI.
For instance, one could switch off the edge node by doing:

```
$> stack exec -- bcc-sl-cluster-demo --edges 0
```

## Known Issues

The current logging implementation of _bcc-sl_ heavily relies on a global mutable state
stored in a shared `MVar`. Since every node in `bcc-sl-cluster-demo` is spawned from a
common parent thread, they all eventually end up sharing the same logging state.

This result in a non-friendly behavior where, every logging handler get replaced by the one
from the next node started by the cluster. So once started, every log entry gets logged _as-if_
they were logged by the last node started (with default parameters, the edge node).

This is why you won't find any log (apart from a couple of lines on start-up) inside log files,
and duplicated lines in one of them (likely `edge.log.pub`); fixing this is non-trivial.

## Troubleshooting

If there are services that already listen to some of the target ports (127.0.0.1:3000,
127.0.0.1:3001 etc.) the following message will be displayed:

```
user error (Giving up waiting for node to start: it takes too long
````

`$> lsof -i :3000` command will show if the port 3000 is used by any process.

See [Configuring Cluster](#Configuring-Cluster) to change the default ports used by
`bcc-sl-cluster-demo`.


<p align="center">
（✿ ͡◕ ᴗ◕ )つ━━✫ ✧･ﾟ* <i>enjoy</i> *:･ﾟ✧*:･ﾟ❤
</p>

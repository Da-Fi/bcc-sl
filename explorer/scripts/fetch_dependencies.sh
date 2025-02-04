#!/bin/sh

items="
https://github.com/serokell/universum.git
https://github.com/serokell/serokell-util.git
https://github.com/serokell/acid-state.git
https://github.com/serokell/log-warper.git
https://github.com/serokell/kademlia.git
https://github.com/serokell/rocksdb-haskell.git
https://github.com/serokell/time-warp-nt.git
https://github.com/serokell/network-transport.git
https://github.com/serokell/network-transport-tcp.git
https://github.com/The-Blockchain-Company/bcc-crypto.git
https://github.com/The-Blockchain-Company/bcc-report-server.git
https://github.com/The-Blockchain-Company/gideon-prototype.git
https://github.com/serokell/engine.io.git
https://github.com/The-Blockchain-Company/bcc-sl.git
"

for item in $items
do
  revision=$(git ls-remote "$item" | grep refs/heads/master | cut -f 1)
  echo "$item $revision"
done

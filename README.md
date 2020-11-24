# What is riak_core_lite?

Riak Core Lite is a framework that simplifies the development of dynamo-style architectures, such as highly-available key-value stores and messaging systems.

Build upon the essence of Riak KV's core with an up-to-date, modular and extensible foundation for elastic distributed services.

# riak_core_lite

![Language](https://img.shields.io/badge/language-erlang-blue.svg)
![Release](https://img.shields.io/badge/release-R21+-9cf.svg)
![Release](https://img.shields.io/badge/formatter-erlang_otp-33d.svg)
![Build](https://img.shields.io/badge/build-rebar3%203.13.0-brightgreen.svg)

[![Hex pm](https://img.shields.io/hexpm/v/riak_core_lite.svg)](https://hex.pm/packages/riak_core_lite)
![Erlang CI](https://github.com/albsch/riak_core_lite/workflows/Erlang%20CI/badge.svg)
[![Coverage Status](https://coveralls.io/repos/github/riak-core-lite/riak_core_lite/badge.svg?branch=master)](https://coveralls.io/github/riak-core-lite/riak_core_lite?branch=master)


To get started with riak_core_lite you can follow Mariano Guerra's tutorials.
They are based on the full riak_core, but are still applicable to riak_core_lite.

1. [Setup](http://marianoguerra.org/posts/riak-core-tutorial-part-1-setup.html)
2. [Starting](http://marianoguerra.org/posts/riak-core-tutorial-part-2-starting.html)
3. [Ping Command](http://marianoguerra.org/posts/riak-core-tutorial-part-3-ping-command.html)
4. [First Commands](http://marianoguerra.org/posts/riak-core-tutorial-part-4-first-commands.html)
5. [Quorum Requests](http://marianoguerra.org/posts/riak-core-tutorial-part-5-quorum-requests.html)
6. [Handoff](http://marianoguerra.org/posts/riak-core-tutorial-part-6-handoff.html)
7. [HTTP API](http://marianoguerra.org/posts/riak-core-tutorial-part-8-http-api.html)
9. [Persistent KV with leveled backend](http://marianoguerra.org/posts/riak-core-tutorial-part-9-persistent-kv-with-leveled-backend.html)

## Contributing

We love community code, bug fixes, and other forms of contribution. We
use GitHub Issues and Pull Requests for contributions to this and all
other code. To get started:

1. Fork this repository.
2. Clone your fork or add the remote if you already have a clone of
   the repository.
3. Create a topic branch for your change.
4. Make your change and commit. Use a clear and descriptive commit
   message, spanning multiple lines if detailed explanation is needed.
5. Push to your fork of the repository and then send a pull request.

6. A committer will review your patch and merge it into the main
   repository or send you feedback.

## Issues, Questions, and Bugs

There are numerous ways to file issues or start conversations around
something Core related

* If you've found a bug in riak_core_lite,
  [file](https://github.com/riak-core-lite/riak_core_lite/issues) a clear, concise,
  explanatory issue against this repo.
  
## Reference Implementation

For some reference on how `riak_core_lite` can be used, you can read about projects which are using `riak_core_lite` as a library:

- [rcl_memkv](https://github.com/albsch/rcl_memkv): A minimalistic in-memory key-value store to understand how to implement the handoff behavior properly
- [rclref](https://github.com/wattlebirdaz/rclref): A reference implementation of a distributed key-value store using riak_core_lite featuring quorum reads and writes.
- [AntidoteDB](https://github.com/AntidoteDB/antidote): A a highly available geo-replicated key-value database which uses riak_core_lite for sharding of data centers.

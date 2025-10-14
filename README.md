# Riak Core

![Riak Core OpenRiak Status](https://github.com/OpenRiak/riak_core/actions/workflows/erlang.yml/badge.svg?branch=openriak-3.4)

Riak Core is the distributed systems framework that forms the basis of how [Riak](https://github.com/OpenRiak/riak) distributes data and scales.
More generally, it can be thought of as a toolkit for building distributed, scalable, fault-tolerant applications.

For some introductory reading on Riak Core (that’s not pure code), there’s an old but still valuable [blog post on the Basho Blog](http://basho.com/where-to-start-with-riak-core/) that’s well worth your time.

This repository retains the history of the original [Basho repository](https://github.com/basho/riak_core/), but is no longer forked from it as the OpenRiak version evolves.

The prior OpenRiak [fork](https://github.com/OpenRiak/riak_core-forked) is retained for historical purposes.

The [riak_core_lite](https://riak-core-lite.github.io/) project also provides a modernised alternative to Riak Core targeted at those intending to build non-Riak applications on a riak_core-like platform.

## OTP version support

Riak is built on top of the [Erlang/OTP platform](https://github.com/erlang/otp).  Supported versions for this release are:

![OTP Recommended](https://img.shields.io/badge/OTP_Recommended_Version-_OTP_26_-green)

![OTP Supported](https://img.shields.io/badge/OTP_Backwards_Compatible-_OTP_24_-blue)

For later OTP versions, an alternative `openriak-<release>` branch will be required.  See [the roadmap discussion](https://github.com/orgs/OpenRiak/discussions/19) for further details.

## Contributing

We love community code, bug fixes, and other forms of contribution. We use GitHub Issues and Pull Requests for contributions to this and all other code. To get started:

1. Fork this repository.
2. Clone your fork or add the remote if you already have a clone of the repository.
3. Create a topic branch for your change.
4. Make your change and commit. Use a clear and descriptive commit message, spanning multiple lines if detailed explanation is needed.
5. Push to your fork of the repository and then send a pull request.
6. An OpenRiak maintainer will review your patch and merge it into the main repository or send you feedback.

## Issues, Questions, and Bugs

There are numerous ways to file issues or start conversations around
something Core related.

- There is an `open-riak` group on the [Slack channel for the Erlang Ecosystem Foundation](https://erlef.org/slack-invite/erlef), where ad-hoc discussions on riak development take place.
- The [Riak Slack](https://postriak.slack.com) is also available for Riak and Core questions.
- Riak Core development initiatives are located in this repo's [discussions](https://github.com/OpenRiak/riak_core/discussions) section, or [the organisation discussion board](https://github.com/orgs/OpenRiak/discussions).
- Known issues are discussed in this repo's [issues](https://github.com/OpenRiak/riak_core/issues) section.
- If you've found a bug in Riak Core, please [file](https://github.com/OpenRiak/riak_core/issues) a clear, concise, explanatory issue against this repo.

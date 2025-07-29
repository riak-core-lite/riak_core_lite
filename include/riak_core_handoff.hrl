-type riak_core_handoff_dict() :: dict:dict().

-define(PT_MSG_INIT, 0).
-define(PT_MSG_OBJ, 1).
-define(PT_MSG_OLDSYNC, 2).
-define(PT_MSG_SYNC, 3).
-define(PT_MSG_CONFIGURE, 4).
-define(PT_MSG_BATCH, 5).

-record(ho_stats,
        {
          interval_end                  :: erlang:timestamp(),
          last_update = os:timestamp()  :: erlang:timestamp(),
          objs=0                        :: non_neg_integer(),
          bytes=0                       :: non_neg_integer()
        }).

-type ho_stats() :: #ho_stats{}.
-type ho_type() :: ownership | hinted | repair | resize.
-type predicate() :: fun((any()) -> boolean()).

-type index() :: chash:index_as_int().
-type mod_src_tgt() :: {module(), index(), index()}.
-type mod_partition() :: {module(), index()}.

-type db_dynamic_size_fun()
  :: fun(() -> db_size()).
-type db_size_result() :: {non_neg_integer(), bytes | objects}.
-type db_size()
  :: {db_dynamic_size_fun(), dynamic} | db_size_result().

-record(handoff_status,
        { mod_src_tgt           :: mod_src_tgt()|undefined,
          src_node              :: node(),
          target_node           :: node(),
          direction             :: inbound | outbound,
          transport_pid         :: pid(),
          transport_mon         :: reference(),
          timestamp             :: tuple(),
          status                :: any(),
          stats                 :: riak_core_handoff_dict(),
          vnode_pid             :: pid() | undefined,
          vnode_mon             :: reference() | undefined,
          type = undefined      :: ho_type() | undefined,
          req_origin            :: node(),
          filter_mod_fun        :: {module(), atom()} | undefined,
          size = {0, objects}   :: db_size() | undefined
        }).
-type handoff_status() :: #handoff_status{}.

-type known_handoff() :: {{module(), index()},
                           {ho_type()|'delete',
                            'inbound'|'outbound'|'local',
                            node()|'$resize'|'$delete'}}.

const std = @import("std");
const network = @import("zig-network");
const EndPoint = network.EndPoint;
const Packet = @import("packet.zig").Packet;
const PACKET_DATA_SIZE = @import("packet.zig").PACKET_DATA_SIZE;

const Thread = std.Thread;
const AtomicBool = std.atomic.Atomic(bool);
const UdpSocket = network.Socket;
const Tuple = std.meta.Tuple;
const SocketAddr = @import("net.zig").SocketAddr;
const _protocol = @import("protocol.zig");
const Protocol = _protocol.Protocol;
const PruneData = _protocol.PruneData;

const Mux = @import("../sync/mux.zig").Mux;
const RwMux = @import("../sync/mux.zig").RwMux;

const Ping = @import("ping_pong.zig").Ping;
const Pong = @import("ping_pong.zig").Pong;
const bincode = @import("../bincode/bincode.zig");
const crds = @import("../gossip/crds.zig");
const CrdsValue = crds.CrdsValue;

const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Pubkey = @import("../core/pubkey.zig").Pubkey;
const get_wallclock = @import("../gossip/crds.zig").get_wallclock;

const _crds_table = @import("../gossip/crds_table.zig");
const CrdsTable = _crds_table.CrdsTable;
const CrdsError = _crds_table.CrdsError;
const HashTimeQueue = _crds_table.HashTimeQueue;
const CRDS_UNIQUE_PUBKEY_CAPACITY = _crds_table.CRDS_UNIQUE_PUBKEY_CAPACITY;

const Logger = @import("../trace/log.zig").Logger;
const Entry = @import("../trace/entry.zig").Entry;

const pull_request = @import("../gossip/pull_request.zig");
const CrdsFilter = pull_request.CrdsFilter;
const MAX_NUM_PULL_REQUESTS = pull_request.MAX_NUM_PULL_REQUESTS;

const pull_response = @import("../gossip/pull_response.zig");
const ActiveSet = @import("../gossip/active_set.zig").ActiveSet;

const Hash = @import("../core/hash.zig").Hash;

const socket_utils = @import("socket_utils.zig");

const Channel = @import("../sync/channel.zig").Channel;
const PacketChannel = Channel(Packet);
const ProtocolMessage = struct { from_endpoint: EndPoint, message: Protocol };
const ProtocolChannel = Channel(ProtocolMessage);

const CRDS_GOSSIP_PULL_CRDS_TIMEOUT_MS: u64 = 15000;
const CRDS_GOSSIP_PUSH_MSG_TIMEOUT_MS: u64 = 30000;
const CRDS_GOSSIP_PRUNE_MSG_TIMEOUT_MS: u64 = 500;

const FAILED_INSERTS_RETENTION_MS: u64 = 20_000;

const MAX_PACKETS_PER_PUSH: usize = 64;
const MAX_BYTES_PER_PUSH: u64 = PACKET_DATA_SIZE * @as(u64, MAX_PACKETS_PER_PUSH);

const PUSH_MESSAGE_MAX_PAYLOAD_SIZE: usize = PACKET_DATA_SIZE - 44;

const GOSSIP_SLEEP_MILLIS: u64 = 1 * std.time.ms_per_s;

/// Maximum number of origin nodes that a PruneData may contain, such that the
/// serialized size of the PruneMessage stays below PACKET_DATA_SIZE.
const MAX_PRUNE_DATA_NODES: usize = 32;
const NUM_ACTIVE_SET_ENTRIES: usize = 25;

pub const GossipService = struct {
    allocator: std.mem.Allocator,

    // note: this contact info should not change
    gossip_socket: UdpSocket,
    my_contact_info: crds.LegacyContactInfo,
    my_keypair: KeyPair,
    my_pubkey: Pubkey,
    my_shred_version: u64,
    exit: *AtomicBool,

    // communication between threads
    packet_channel: *PacketChannel,
    responder_channel: *PacketChannel,
    verified_channel: *ProtocolChannel,

    crds_table_rw: RwMux(CrdsTable),
    // push message things
    active_set_rw: RwMux(ActiveSet),
    push_msg_queue_mux: Mux(std.ArrayList(CrdsValue)),
    // pull message things
    failed_pull_hashes_mux: Mux(HashTimeQueue),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        my_contact_info: crds.LegacyContactInfo,
        my_keypair: KeyPair,
        exit: *AtomicBool,
    ) error{ OutOfMemory, SocketCreateFailed, SocketBindFailed, SocketSetTimeoutFailed }!Self {
        var packet_channel = PacketChannel.init(allocator, 10000);
        var verified_channel = ProtocolChannel.init(allocator, 10000);
        var responder_channel = PacketChannel.init(allocator, 10000);
        errdefer {
            packet_channel.deinit();
            verified_channel.deinit();
            responder_channel.deinit();
        }

        var crds_table = try CrdsTable.init(allocator);
        errdefer crds_table.deinit();
        var crds_table_rw = RwMux(CrdsTable).init(crds_table);
        var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, false);
        var my_shred_version = my_contact_info.shred_version;
        var active_set = ActiveSet.init(allocator);

        // bind the socket
        const gossip_address = my_contact_info.gossip;
        if (gossip_address.is_unspecified()) {
            return error.SocketBindFailed;
        }
        var gossip_socket = UdpSocket.create(.ipv4, .udp) catch return error.SocketCreateFailed;
        gossip_socket.bind(gossip_address.toEndpoint()) catch return error.SocketBindFailed;
        gossip_socket.setReadTimeout(1000000) catch return error.SocketSetTimeoutFailed; // 1 second

        var failed_pull_hashes = HashTimeQueue.init(allocator);
        var push_msg_q = std.ArrayList(CrdsValue).init(allocator);

        return Self{
            .my_contact_info = my_contact_info,
            .my_keypair = my_keypair,
            .my_pubkey = my_pubkey,
            .my_shred_version = my_shred_version,
            .gossip_socket = gossip_socket,
            .exit = exit,
            .packet_channel = packet_channel,
            .responder_channel = responder_channel,
            .verified_channel = verified_channel,
            .crds_table_rw = crds_table_rw,
            .allocator = allocator,
            .push_msg_queue_mux = Mux(std.ArrayList(CrdsValue)).init(push_msg_q),
            .active_set_rw = RwMux(ActiveSet).init(active_set),
            .failed_pull_hashes_mux = Mux(HashTimeQueue).init(failed_pull_hashes),
        };
    }

    fn deinit_rw_mux(v: anytype) void {
        var lg = v.write();
        lg.mut().deinit();
        lg.unlock();
    }

    fn deinit_mux(v: anytype) void {
        var lg = v.lock();
        lg.mut().deinit();
        lg.unlock();
    }

    pub fn deinit(self: *Self) void {
        // TODO: join and exit threads
        self.packet_channel.deinit();
        self.responder_channel.deinit();
        self.verified_channel.deinit();

        deinit_rw_mux(&self.crds_table_rw);
        deinit_rw_mux(&self.active_set_rw);
        deinit_mux(&self.push_msg_queue_mux);
        deinit_mux(&self.failed_pull_hashes_mux);
    }

    /// these threads should run forever - so if they join - somethings wrong
    /// and we should shutdown
    fn join_and_exit(self: *Self, handle: *std.Thread) void {
        handle.join();
        self.exit.store(true, std.atomic.Ordering.Unordered);
    }

    /// spawns required threads for the gossip serivce.
    /// including:
    ///     1) socket reciever
    ///     2) packet verifier
    ///     3) packet processor
    ///     4) build message loop (to send outgoing message)
    ///     and 5) a socket responder (to send outgoing packets)
    pub fn run(self: *Self, logger: *Logger) !void {
        var receiver_handle = try Thread.spawn(.{}, socket_utils.read_socket, .{
            &self.gossip_socket,
            self.packet_channel,
            self.exit,
        });
        defer self.join_and_exit(&receiver_handle);

        var packet_verifier_handle = try Thread.spawn(.{}, Self.verify_packets, .{
            self, logger,
        });
        defer self.join_and_exit(&packet_verifier_handle);

        var packet_handle = try Thread.spawn(.{}, Self.process_messages, .{
            self, logger,
        });
        defer self.join_and_exit(&packet_handle);

        var build_messages_handle = try Thread.spawn(.{}, Self.build_messages, .{
            self,
            logger,
        });
        defer self.join_and_exit(&build_messages_handle);

        // outputer thread
        var responder_handle = try Thread.spawn(.{}, socket_utils.send_socket, .{
            &self.gossip_socket,
            self.responder_channel,
            self.exit,
        });
        defer self.join_and_exit(&responder_handle);
    }

    /// main logic for deserializing Packets into Protocol messages
    /// and verifing they have valid values, and have valid signatures.
    /// Verified Protocol messages are then sent to the verified_channel.
    fn verify_packets(self: *Self, logger: *Logger) !void {
        var failed_protocol_msgs: usize = 0;

        while (!self.exit.load(std.atomic.Ordering.Unordered)) {
            const maybe_packets = try self.packet_channel.try_drain();
            if (maybe_packets == null) {
                // sleep for 1ms
                std.time.sleep(std.time.ns_per_ms * 1);
                continue;
            }

            const packets = maybe_packets.?;
            defer self.packet_channel.allocator.free(packets);

            for (packets) |packet| {
                var protocol_message = bincode.readFromSlice(
                    self.allocator,
                    Protocol,
                    packet.data[0..packet.size],
                    bincode.Params.standard,
                ) catch {
                    failed_protocol_msgs += 1;
                    logger.debugf("failed to deserialize protocol message\n", .{});
                    continue;
                };

                protocol_message.sanitize() catch |err| {
                    logger.debugf("failed to sanitize protocol message: {s}\n", .{@errorName(err)});
                    bincode.free(self.allocator, protocol_message);
                    continue;
                };

                protocol_message.verify_signature() catch |err| {
                    logger.debugf("failed to verify protocol message signature {s}\n", .{@errorName(err)});
                    bincode.free(self.allocator, protocol_message);
                    continue;
                };

                // TODO: send the pointers over the channel (similar to PinnedVec) vs item copy
                const msg = ProtocolMessage{ .from_endpoint = packet.addr, .message = protocol_message };
                try self.verified_channel.send(msg);
            }
        }

        logger.debugf("verify_packets loop closed\n", .{});
    }

    /// main logic for recieving and processing `Protocol` messages.
    pub fn process_messages(self: *Self, logger: *Logger) !void {
        while (!self.exit.load(std.atomic.Ordering.Unordered)) {
            const maybe_protocol_messages = try self.verified_channel.try_drain();
            if (maybe_protocol_messages == null) {
                // sleep for 1ms
                std.time.sleep(std.time.ns_per_ms * 1);
                continue;
            }

            const protocol_messages = maybe_protocol_messages.?;
            defer self.verified_channel.allocator.free(protocol_messages);

            for (protocol_messages) |protocol_message| {
                var message: Protocol = protocol_message.message;
                var from_endpoint: EndPoint = protocol_message.from_endpoint;

                switch (message) {
                    .PushMessage => |*push| {
                        const push_from: Pubkey = push[0];
                        const push_values: []CrdsValue = push[1];

                        var push_log_entry = logger
                            .field("num_crds_values", push_values.len)
                            .field("from_address", &push_from.string());

                        var failed_insert_origins = self.handle_push_message(
                            push_values,
                        ) catch |err| {
                            push_log_entry.field("error", @errorName(err))
                                .err("error handling push message");
                            continue;
                        };
                        defer failed_insert_origins.deinit();
                        _ = push_log_entry.field("num_failed_insert_origins", failed_insert_origins.count());

                        if (failed_insert_origins.count() != 0) {
                            var prune_packets = self.build_prune_message(&failed_insert_origins, push_from) catch |err| {
                                push_log_entry.field("error", @errorName(err))
                                    .err("error building prune messages");
                                continue;
                            };
                            defer prune_packets.deinit();

                            _ = push_log_entry.field("num_prune_msgs", prune_packets.items.len);
                            for (prune_packets.items) |packet| {
                                try self.responder_channel.send(packet);
                            }
                        }

                        push_log_entry.info("received push message");
                    },
                    .PullResponse => |*pull| {
                        const from: Pubkey = pull[0];
                        const crds_values: []CrdsValue = pull[1];

                        var pull_log_entry = logger
                            .field("num_crds_values", crds_values.len)
                            .field("from_address", &from.string());

                        self.handle_pull_response(
                            crds_values,
                            pull_log_entry,
                        ) catch |err| {
                            pull_log_entry.field("error", @errorName(err))
                                .err("error handling pull response");
                            continue;
                        };

                        pull_log_entry.info("received pull response");
                    },
                    .PullRequest => |*pull| {
                        var pull_filter: CrdsFilter = pull[0];
                        var pull_value: CrdsValue = pull[1]; // contact info

                        var endpoint_buf = std.ArrayList(u8).init(self.allocator);
                        try from_endpoint.format(&[_]u8{}, std.fmt.FormatOptions{}, endpoint_buf.writer());
                        defer endpoint_buf.deinit();

                        var pull_log_entry = logger
                            .field("from_endpoint", endpoint_buf.items)
                            .field("from_pubkey", &pull_value.id().string());

                        var packets = self.handle_pull_request(
                            pull_value,
                            pull_filter,
                            from_endpoint,
                            pull_log_entry,
                        ) catch |err| {
                            pull_log_entry.field("error", @errorName(err))
                                .err("error handling pull request");
                            continue;
                        };
                        defer packets.deinit();

                        pull_log_entry.field("num_packets_resp", packets.items.len)
                            .info("received pull request");

                        for (packets.items) |packet| {
                            try self.responder_channel.send(packet);
                        }
                    },
                    .PruneMessage => |*prune| {
                        const prune_msg: PruneData = prune[1];

                        var endpoint_buf = std.ArrayList(u8).init(self.allocator);
                        try from_endpoint.format(&[_]u8{}, std.fmt.FormatOptions{}, endpoint_buf.writer());
                        defer endpoint_buf.deinit();

                        var prune_log_entry = logger
                            .field("from_endpoint", endpoint_buf.items)
                            .field("from_pubkey", &prune_msg.pubkey.string())
                            .field("num_prunes", prune_msg.prunes.len);

                        self.handle_prune_message(
                            &prune_msg,
                        ) catch |err| {
                            prune_log_entry.field("error", @errorName(err))
                                .err("error handling prune message");
                            continue;
                        };

                        prune_log_entry.info("received prune message");
                    },
                    .PingMessage => |*ping| {
                        var endpoint_buf = std.ArrayList(u8).init(self.allocator);
                        try from_endpoint.format(&[_]u8{}, std.fmt.FormatOptions{}, endpoint_buf.writer());
                        defer endpoint_buf.deinit();

                        var ping_log_entry = logger
                            .field("from_endpoint", endpoint_buf.items)
                            .field("from_pubkey", &ping.from.string());

                        const packet = self.handle_ping_message(ping, from_endpoint) catch |err| {
                            ping_log_entry
                                .field("error", @errorName(err))
                                .err("error handling ping message");
                            continue;
                        };

                        try self.responder_channel.send(packet);
                        ping_log_entry.info("received ping message");
                    },
                    .PongMessage => |*pong| {
                        var endpoint_buf = std.ArrayList(u8).init(self.allocator);
                        try from_endpoint.format(&[_]u8{}, std.fmt.FormatOptions{}, endpoint_buf.writer());
                        defer endpoint_buf.deinit();

                        logger
                            .field("from_endpoint", endpoint_buf.items)
                            .field("from_pubkey", &pong.from.string())
                            .info("received pong message");
                    },
                }

                {
                    var crds_table_lg = self.crds_table_rw.write();
                    defer crds_table_lg.unlock();

                    var crds_table: *CrdsTable = crds_table_lg.mut();
                    crds_table.attempt_trim(CRDS_UNIQUE_PUBKEY_CAPACITY) catch |err| {
                        logger.warnf("error trimming crds table: {s}", .{@errorName(err)});
                    };
                }
            }
        }

        logger.debugf("process_messages loop closed\n", .{});
    }

    /// main gossip loop for periodically sending new protocol messages.
    /// this includes sending push messages, pull requests, and triming old
    /// gossip data (in the crds_table, active_set, and failed_pull_hashes).
    fn build_messages(
        self: *Self,
        /// logger used for debugging
        logger: *Logger,
    ) !void {
        var last_push_ts: u64 = 0;
        var push_cursor: u64 = 0;
        var should_send_pull_requests = true;

        while (!self.exit.load(std.atomic.Ordering.Unordered)) {
            const top_of_loop_ts = get_wallclock();

            // TODO: send ping messages based on PingCache

            // new pull msgs
            if (should_send_pull_requests) pull_blk: {
                var pull_packets = self.build_pull_requests(
                    pull_request.MAX_BLOOM_SIZE,
                ) catch |e| {
                    logger.debugf("failed to generate pull requests: {any}", .{e});
                    break :pull_blk;
                };
                defer pull_packets.deinit();

                // send packets
                for (pull_packets.items) |packet| {
                    try self.responder_channel.send(packet);
                }
            }
            // every other loop
            should_send_pull_requests = !should_send_pull_requests;

            // new push msgs
            self.drain_push_queue_to_crds_table(get_wallclock());
            var maybe_push_packets = self.build_push_messages(&push_cursor) catch |e| blk: {
                logger.debugf("failed to generate push messages: {any}\n", .{e});
                break :blk null;
            };
            if (maybe_push_packets) |push_packets| {
                defer push_packets.deinit();
                for (push_packets.items) |packet| {
                    try self.responder_channel.send(packet);
                }
            }

            // trim data
            self.trim_memory(get_wallclock()) catch @panic("out of memory");

            // periodic things
            if (top_of_loop_ts - last_push_ts > CRDS_GOSSIP_PULL_CRDS_TIMEOUT_MS / 2) {
                // update wallclock and sign
                self.my_contact_info.wallclock = get_wallclock();
                var my_contact_info_value = try crds.CrdsValue.initSigned(crds.CrdsData{
                    .LegacyContactInfo = self.my_contact_info,
                }, &self.my_keypair);

                // push contact info
                {
                    var push_msg_queue_lg = self.push_msg_queue_mux.lock();
                    defer push_msg_queue_lg.unlock();
                    var push_msg_queue: *std.ArrayList(CrdsValue) = push_msg_queue_lg.mut();

                    try push_msg_queue.append(my_contact_info_value);
                }

                self.rotate_active_set() catch @panic("out of memory");

                last_push_ts = get_wallclock();
            }

            // sleep
            const elapsed_ts = get_wallclock() - top_of_loop_ts;
            if (elapsed_ts < GOSSIP_SLEEP_MILLIS) {
                const time_left_ms = GOSSIP_SLEEP_MILLIS - elapsed_ts;
                std.time.sleep(time_left_ms * std.time.ns_per_ms);
            }
        }
        logger.infof("build_messages loop closed\n", .{});
    }

    pub fn rotate_active_set(
        self: *Self,
    ) error{OutOfMemory}!void {
        const now = get_wallclock();
        var buf: [NUM_ACTIVE_SET_ENTRIES]crds.LegacyContactInfo = undefined;
        var gossip_peers = self.get_gossip_nodes(&buf, NUM_ACTIVE_SET_ENTRIES, now);

        // reset push active set
        var active_set_lg = self.active_set_rw.write();
        defer active_set_lg.unlock();
        var active_set: *ActiveSet = active_set_lg.mut();
        try active_set.rotate(gossip_peers);
    }

    /// logic for building new push messages which are sent to peers from the
    /// active set and serialized into packets.
    fn build_push_messages(self: *Self, push_cursor: *u64) !?std.ArrayList(Packet) {
        // TODO: find a better static value?
        var buf: [512]crds.CrdsVersionedValue = undefined;

        var crds_entries = blk: {
            var crds_table_lg = self.crds_table_rw.read();
            defer crds_table_lg.unlock();

            const crds_table: *const CrdsTable = crds_table_lg.get();
            break :blk crds_table.get_entries_with_cursor(&buf, push_cursor);
        };

        if (crds_entries.len == 0) {
            return null;
        }

        const now = get_wallclock();
        var total_byte_size: usize = 0;

        // find new values in crds table
        // TODO: benchmark different approach of HashMapping(origin, value) first
        // then deriving the active set per origin in a batch
        var push_messages = std.AutoHashMap(EndPoint, std.ArrayList(CrdsValue)).init(self.allocator);
        defer push_messages.deinit();

        var active_set_lg = self.active_set_rw.read();
        var active_set: *const ActiveSet = active_set_lg.get();
        errdefer active_set_lg.unlock();

        var num_values_considered: usize = 0;
        for (crds_entries) |entry| {
            const value = entry.value;

            const entry_time = value.wallclock();
            const too_old = entry_time < now -| CRDS_GOSSIP_PUSH_MSG_TIMEOUT_MS;
            const too_new = entry_time > now +| CRDS_GOSSIP_PUSH_MSG_TIMEOUT_MS;
            if (too_old or too_new) {
                num_values_considered += 1;
                continue;
            }

            const byte_size = try bincode.get_serialized_size(self.allocator, value, bincode.Params{});
            total_byte_size +|= byte_size;

            if (total_byte_size > MAX_BYTES_PER_PUSH) {
                break;
            }

            // get the active set for these values *PER ORIGIN* due to prunes
            const origin = value.id();
            var active_set_peers = blk: {
                var crds_table_lg = self.crds_table_rw.read();
                defer crds_table_lg.unlock();
                const crds_table: *const CrdsTable = crds_table_lg.get();

                break :blk try active_set.get_fanout_peers(self.allocator, origin, crds_table);
            };
            defer active_set_peers.deinit();

            for (active_set_peers.items) |peer| {
                var maybe_peer_entry = push_messages.getEntry(peer);
                if (maybe_peer_entry) |peer_entry| {
                    try peer_entry.value_ptr.append(value);
                } else {
                    var peer_entry = try std.ArrayList(CrdsValue).initCapacity(self.allocator, 1);
                    peer_entry.appendAssumeCapacity(value);
                    try push_messages.put(peer, peer_entry);
                }
            }
            num_values_considered += 1;
        }
        active_set_lg.unlock();

        // adjust cursor for values not sent this round
        // NOTE: labs client doesnt do this - bug?
        const num_values_not_considered = crds_entries.len - num_values_considered;
        push_cursor.* -= num_values_not_considered;

        // build Push msg packets
        var all_crds_values = try std.ArrayList(*const std.ArrayList(CrdsValue)).initCapacity(self.allocator, push_messages.count());
        var all_endpoints = try std.ArrayList(*const EndPoint).initCapacity(self.allocator, push_messages.count());
        defer {
            for (all_crds_values.items) |all_crds_value| {
                all_crds_value.deinit();
            }
            all_crds_values.deinit();
            all_endpoints.deinit();
        }

        var push_iter = push_messages.iterator();
        while (push_iter.next()) |push_entry| {
            all_crds_values.appendAssumeCapacity(push_entry.value_ptr);
            all_endpoints.appendAssumeCapacity(push_entry.key_ptr);
        }

        const push_packets = try PacketBuilder.PushMessage.build_packets(
            self.allocator,
            self.my_pubkey,
            &all_crds_values,
            &all_endpoints,
            PUSH_MESSAGE_MAX_PAYLOAD_SIZE,
        );

        return push_packets;
    }

    /// builds new pull request messages and serializes it into a list of Packets
    /// to be sent to a random set of gossip nodes.
    fn build_pull_requests(
        self: *Self,
        /// the bloomsize of the pull request's filters
        bloom_size: usize,
    ) !std.ArrayList(Packet) {
        // compute failed pull crds hash values
        const failed_pull_hashes_array = blk: {
            var failed_pull_hashes_lg = self.failed_pull_hashes_mux.lock();
            defer failed_pull_hashes_lg.unlock();

            const failed_pull_hashes: *const HashTimeQueue = failed_pull_hashes_lg.get();
            break :blk try failed_pull_hashes.get_values();
        };
        defer failed_pull_hashes_array.deinit();

        // build crds filters
        var filters = try pull_request.build_crds_filters(
            self.allocator,
            &self.crds_table_rw,
            &failed_pull_hashes_array,
            bloom_size,
            MAX_NUM_PULL_REQUESTS,
        );
        defer pull_request.deinit_crds_filters(&filters);

        // get nodes from crds table
        var buf: [MAX_NUM_PULL_REQUESTS]crds.LegacyContactInfo = undefined;
        const now = get_wallclock();
        var peers = self.get_gossip_nodes(
            &buf,
            MAX_NUM_PULL_REQUESTS,
            now,
        );

        const num_peers = peers.len;
        if (num_peers == 0) {
            return error.NoPeers;
        }

        // build packet responses
        var output = try std.ArrayList(Packet).initCapacity(self.allocator, filters.items.len);
        var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;

        // update wallclock and sign
        self.my_contact_info.wallclock = now;
        const my_contact_info_value = try crds.CrdsValue.initSigned(crds.CrdsData{
            .LegacyContactInfo = self.my_contact_info,
        }, &self.my_keypair);

        var rng = std.rand.DefaultPrng.init(now);
        for (filters.items) |filter_i| {
            // TODO: incorperate stake weight in random sampling
            const peer_index = rng.random().intRangeAtMost(usize, 0, num_peers - 1);
            const peer_contact_info = peers[peer_index];
            const peer_addr = peer_contact_info.gossip.toEndpoint();

            const protocol_msg = Protocol{ .PullRequest = .{ filter_i, my_contact_info_value } };

            var msg_slice = try bincode.writeToSlice(&packet_buf, protocol_msg, bincode.Params{});
            var packet = Packet.init(peer_addr, packet_buf, msg_slice.len);
            output.appendAssumeCapacity(packet);
        }

        return output;
    }

    /// logic for handling a pull request message
    /// values which are missing in the pull request filter are returned as a pull response
    /// which are serialized into packets.
    fn handle_pull_request(
        self: *Self,
        /// the crds value associated with the pull request
        pull_value: CrdsValue,
        /// the crds filter of the pull request
        pull_filter: CrdsFilter,
        /// the endpoint of the peer sending the pull request (/who to send the pull response to)
        pull_from_endpoint: EndPoint,
        // logging
        maybe_log_entry: ?*Entry,
    ) error{ SerializationError, OutOfMemory }!std.ArrayList(Packet) {
        const now = get_wallclock();

        {
            var crds_table_lg = self.crds_table_rw.write();
            defer crds_table_lg.unlock();
            var crds_table = crds_table_lg.mut();

            crds_table.insert(pull_value, now) catch {};
            crds_table.update_record_timestamp(pull_value.id(), now);
        }

        // TODO: filter out requests which hasnt responded to a ping request

        const MAX_NUM_CRDS_VALUES_PULL_RESPONSE = 100; // TODO: tune
        var crds_table_lg = self.crds_table_rw.read();
        errdefer crds_table_lg.unlock();
        const crds_values = try pull_response.filter_crds_values(
            self.allocator,
            crds_table_lg.get(),
            &pull_filter,
            pull_value.wallclock(),
            MAX_NUM_CRDS_VALUES_PULL_RESPONSE,
        );
        defer crds_values.deinit();
        crds_table_lg.unlock();

        if (maybe_log_entry) |log_entry| {
            _ = log_entry.field("num_crds_values_resp", crds_values.items.len);
        }

        // send the values as a pull response
        var all_crds_values = try std.ArrayList(*const std.ArrayList(CrdsValue)).initCapacity(self.allocator, 1);
        var all_to_endpoints = try std.ArrayList(*const EndPoint).initCapacity(self.allocator, 1);
        all_crds_values.appendAssumeCapacity(&crds_values);
        all_to_endpoints.appendAssumeCapacity(&pull_from_endpoint);
        defer {
            all_crds_values.deinit();
            all_to_endpoints.deinit();
        }

        return try PacketBuilder.PullResponse.build_packets(
            self.allocator,
            self.my_pubkey,
            &all_crds_values,
            &all_to_endpoints,
            PUSH_MESSAGE_MAX_PAYLOAD_SIZE,
        );
    }

    /// logic for handling a pull response message.
    /// successful inserted values, have their origin value timestamps updated.
    /// failed inserts (ie, too old or duplicate values) are added to the failed pull hashes so that they can be
    /// included in the next pull request (so we dont receive them again).
    fn handle_pull_response(
        self: *Self,
        /// the array of values to insert into the crds table
        crds_values: []CrdsValue,
        // logging info
        maybe_pull_log_entry: ?*Entry,
    ) error{OutOfMemory}!void {
        // TODO: benchmark and compare with labs' preprocessing
        const now = get_wallclock();
        var crds_table_lg = self.crds_table_rw.write();
        var crds_table: *CrdsTable = crds_table_lg.mut();

        const insert_results = try crds_table.insert_values(
            crds_values,
            CRDS_GOSSIP_PULL_CRDS_TIMEOUT_MS,
            true,
            true,
        );

        // silently insert the timeout values
        // (without updating all associated origin values)
        const timeout_indexs = insert_results.timeouts.?;
        defer timeout_indexs.deinit();
        for (timeout_indexs.items) |index| {
            crds_table.insert(
                crds_values[index],
                now,
            ) catch {};
        }

        // update the contactInfo timestamps of the successful inserts
        // (and all other origin values)
        const successful_insert_indexs = insert_results.inserted.?;
        defer successful_insert_indexs.deinit();
        for (successful_insert_indexs.items) |index| {
            const origin = crds_values[index].id();
            crds_table.update_record_timestamp(origin, now);
        }
        crds_table_lg.unlock();

        // track failed inserts - to use when constructing pull requests
        var failed_insert_indexs = insert_results.failed.?;
        defer failed_insert_indexs.deinit();
        {
            var failed_pull_hashes_lg = self.failed_pull_hashes_mux.lock();
            var failed_pull_hashes: *HashTimeQueue = failed_pull_hashes_lg.mut();
            defer failed_pull_hashes_lg.unlock();

            const failed_insert_cutoff_timestamp = now -| FAILED_INSERTS_RETENTION_MS;
            try failed_pull_hashes.trim(failed_insert_cutoff_timestamp);

            var buf: [PACKET_DATA_SIZE]u8 = undefined;
            for (failed_insert_indexs.items) |insert_index| {
                const value = crds_values[insert_index];
                var bytes = bincode.writeToSlice(&buf, value, bincode.Params.standard) catch {
                    std.debug.print("handle_pull_response: failed to serialize crds value: {any}\n", .{value});
                    continue;
                };
                const value_hash = Hash.generateSha256Hash(bytes);

                try failed_pull_hashes.insert(value_hash, now);
            }
        }

        // update logs
        if (maybe_pull_log_entry) |pull_log_entry| {
            _ = pull_log_entry
                .field("num_timeout_values", timeout_indexs.items.len)
                .field("num_success_insert_values", successful_insert_indexs.items.len)
                .field("num_failed_insert_values", failed_insert_indexs.items.len);
        }
    }

    /// logic for handling a prune message. verifies the prune message
    /// is not too old, and that the destination pubkey is the local node,
    /// then updates the active set to prune the list of origin Pubkeys.
    fn handle_prune_message(
        self: *Self,
        /// the prune message to process
        prune_data: *const PruneData,
    ) error{ PruneMessageTooOld, BadDestination }!void {
        const now = get_wallclock();
        const prune_wallclock = prune_data.wallclock;
        const too_old = prune_wallclock < now -| CRDS_GOSSIP_PRUNE_MSG_TIMEOUT_MS;
        if (too_old) {
            return error.PruneMessageTooOld;
        }

        const bad_destination = !prune_data.destination.equals(&self.my_pubkey);
        if (bad_destination) {
            return error.BadDestination;
        }

        // update active set
        const from_pubkey = prune_data.pubkey;

        var active_set_lg = self.active_set_rw.write();
        defer active_set_lg.unlock();

        var active_set: *ActiveSet = active_set_lg.mut();
        for (prune_data.prunes) |origin| {
            if (origin.equals(&self.my_pubkey)) {
                continue;
            }
            active_set.prune(from_pubkey, origin);
        }
    }

    /// builds a prune message for a list of origin Pubkeys and serializes the values
    /// into packets to send to the prune_destination.
    fn build_prune_message(
        self: *Self,
        /// origin Pubkeys which will be pruned
        failed_origins: *const std.AutoArrayHashMap(Pubkey, void),
        /// the pubkey of the node which we will send the prune message to
        prune_destination: Pubkey,
    ) error{ CantFindContactInfo, InvalidGossipAddress, OutOfMemory, SignatureError }!std.ArrayList(Packet) {
        const from_contact_info = blk: {
            var crds_table_lg = self.crds_table_rw.read();
            defer crds_table_lg.unlock();

            const crds_table: *const CrdsTable = crds_table_lg.get();
            break :blk crds_table.get(crds.CrdsValueLabel{ .LegacyContactInfo = prune_destination }) orelse {
                return error.CantFindContactInfo;
            };
        };
        const from_gossip_addr = from_contact_info.value.data.LegacyContactInfo.gossip;
        crds.sanitize_socket(&from_gossip_addr) catch return error.InvalidGossipAddress;
        const from_gossip_endpoint = from_gossip_addr.toEndpoint();

        const failed_origin_len = failed_origins.keys().len;
        var n_packets = failed_origins.keys().len / MAX_PRUNE_DATA_NODES;
        var prune_packets = try std.ArrayList(Packet).initCapacity(self.allocator, n_packets);
        errdefer prune_packets.deinit();

        var origin_buf: [MAX_PRUNE_DATA_NODES]Pubkey = undefined;
        var origin_count: usize = 0;

        const now = get_wallclock();
        var buf: [PACKET_DATA_SIZE]u8 = undefined;
        const my_pubkey = Pubkey.fromPublicKey(&self.my_keypair.public_key, true);

        for (failed_origins.keys(), 0..) |origin, i| {
            origin_buf[origin_count] = origin;
            origin_count += 1;

            const is_last_iter = i == failed_origin_len - 1;
            if (origin_count == MAX_PRUNE_DATA_NODES or is_last_iter) {
                // create protocol message
                var prune_data = PruneData.init(my_pubkey, origin_buf[0..origin_count], prune_destination, now);
                prune_data.sign(&self.my_keypair) catch return error.SignatureError;

                // put it into a packet
                var msg = Protocol{ .PruneMessage = .{ my_pubkey, prune_data } };
                // msg should never be bigger than the PacketSize and serialization shouldnt fail (unrecoverable)
                var msg_slice = bincode.writeToSlice(&buf, msg, bincode.Params{}) catch unreachable;
                var packet = Packet.init(from_gossip_endpoint, buf, msg_slice.len);
                try prune_packets.append(packet);

                // reset array
                origin_count = 0;
            }
        }

        return prune_packets;
    }

    /// logic for handling push messages. crds values from the push message
    /// are inserted into the crds table. the origin pubkeys of values which
    /// fail the insertion are returned to generate prune messages.
    fn handle_push_message(
        self: *Self,
        push_values: []CrdsValue,
    ) error{OutOfMemory}!std.AutoArrayHashMap(Pubkey, void) {
        const failed_insert_indexs = blk: {
            var crds_table_lg = self.crds_table_rw.write();
            defer crds_table_lg.unlock();

            var crds_table: *CrdsTable = crds_table_lg.mut();
            std.debug.print("crds table len: {d}\n", .{crds_table.len()});

            var result = try crds_table.insert_values(
                push_values,
                CRDS_GOSSIP_PUSH_MSG_TIMEOUT_MS,
                false,
                false,
            );
            break :blk result.failed.?;
        };
        defer failed_insert_indexs.deinit();

        // origins are used to generate prune messages
        // hashmap to account for duplicates
        var failed_origins = std.AutoArrayHashMap(Pubkey, void).init(self.allocator);
        errdefer failed_origins.deinit();

        if (failed_insert_indexs.items.len == 0) {
            return failed_origins;
        }

        for (failed_insert_indexs.items) |index| {
            const origin = push_values[index].id();
            try failed_origins.put(origin, {});
        }
        return failed_origins;
    }

    /// builds a corresponding Pong message for a given Ping message and serializes the
    /// protocol message into a Packet.
    fn handle_ping_message(
        self: *Self,
        /// the ping message to build a Pong message for
        ping: *const Ping,
        /// the endpoint to send the Pong message
        from_endpoint: EndPoint,
    ) error{ SignatureError, SerializationError }!Packet {
        const pong = try Pong.init(ping, &self.my_keypair);
        const pong_message = Protocol{
            .PongMessage = pong,
        };

        // write to packet
        var buf: [PACKET_DATA_SIZE]u8 = undefined;
        const msg = bincode.writeToSlice(&buf, pong_message, bincode.Params.standard) catch return error.SerializationError;
        const packet = Packet.init(from_endpoint, buf, msg.len);

        return packet;
    }

    /// removes old values from the crds table and failed pull hashes struct
    /// based on the current time. This includes triming the purged values from the
    /// crds table, triming the max number of pubkeys in the crds table, and removing
    /// old labels from the crds table.
    fn trim_memory(
        self: *Self,
        /// the current time
        now: u64,
    ) error{OutOfMemory}!void {
        const purged_cutoff_timestamp = now -| (5 * CRDS_GOSSIP_PULL_CRDS_TIMEOUT_MS);
        {
            var crds_table_lg = self.crds_table_rw.write();
            defer crds_table_lg.unlock();
            var crds_table: *CrdsTable = crds_table_lg.mut();

            try crds_table.purged.trim(purged_cutoff_timestamp);
            try crds_table.attempt_trim(CRDS_UNIQUE_PUBKEY_CAPACITY);
            try crds_table.remove_old_labels(now, CRDS_GOSSIP_PULL_CRDS_TIMEOUT_MS);
        }

        const failed_insert_cutoff_timestamp = now -| FAILED_INSERTS_RETENTION_MS;
        {
            var failed_pull_hashes_lg = self.failed_pull_hashes_mux.lock();
            defer failed_pull_hashes_lg.unlock();
            var failed_pull_hashes: *HashTimeQueue = failed_pull_hashes_lg.mut();

            try failed_pull_hashes.trim(failed_insert_cutoff_timestamp);
        }
    }

    /// drains values from the push queue and inserts them into the crds table.
    /// when inserting values in the crds table, any errors are ignored.
    fn drain_push_queue_to_crds_table(
        self: *Self,
        /// the current time to insert the values with
        now: u64,
    ) void {
        var push_msg_queue_lg = self.push_msg_queue_mux.lock();
        defer push_msg_queue_lg.unlock();
        var push_msg_queue: *std.ArrayList(CrdsValue) = push_msg_queue_lg.mut();

        var crds_table_lg = self.crds_table_rw.write();
        defer crds_table_lg.unlock();
        var crds_table: *CrdsTable = crds_table_lg.mut();

        while (push_msg_queue.popOrNull()) |crds_value| {
            crds_table.insert(crds_value, now) catch {};
        }
    }

    /// returns a list of valid gossip nodes. this works by reading
    /// the contact infos from the crds table and filtering out
    /// nodes that are 1) too old, 2) have a different shred version, or 3) have
    /// an invalid gossip address.
    pub fn get_gossip_nodes(
        self: *Self,
        /// the output slice which will be filled with gossip nodes
        nodes: []crds.LegacyContactInfo,
        /// the maximum number of nodes to return ( max_size == nodes.len but comptime for init of stack array)
        comptime MAX_SIZE: usize,
        /// current time (used to filter out nodes that are too old)
        now: u64,
    ) []crds.LegacyContactInfo {
        std.debug.assert(MAX_SIZE == nodes.len);

        var buf: [MAX_SIZE]crds.CrdsVersionedValue = undefined;
        const contact_infos = blk: {
            var crds_table_lg = self.crds_table_rw.read();
            defer crds_table_lg.unlock();

            var crds_table: *const CrdsTable = crds_table_lg.get();
            break :blk crds_table.get_contact_infos(&buf);
        };

        if (contact_infos.len == 0) {
            return nodes[0..0];
        }

        // filter only valid gossip addresses
        const GOSSIP_ACTIVE_TIMEOUT = 60 * std.time.ms_per_s;
        const too_old_ts = now -| GOSSIP_ACTIVE_TIMEOUT;

        var node_index: usize = 0;
        for (contact_infos) |contact_info| {
            const peer_info = contact_info.value.data.LegacyContactInfo;
            const peer_gossip_addr = peer_info.gossip;

            // filter inactive nodes
            if (contact_info.timestamp_on_insertion < too_old_ts) {
                continue;
            }
            // filter self
            if (contact_info.value.id().equals(&self.my_pubkey)) {
                continue;
            }
            // filter matching shred version or my_shred_version == 0
            if (self.my_shred_version != 0 and self.my_shred_version != peer_info.shred_version) {
                continue;
            }
            // filter on valid gossip address
            crds.sanitize_socket(&peer_gossip_addr) catch continue;

            nodes[node_index] = peer_info;
            node_index += 1;

            if (node_index == nodes.len) {
                break;
            }
        }

        return nodes[0..node_index];
    }
};

const PacketBuilder = enum {
    PullResponse,
    PushMessage,

    fn build_packets(
        self: PacketBuilder,
        allocator: std.mem.Allocator,
        my_pubkey: Pubkey,
        to_crds_values: *const std.ArrayList(*const std.ArrayList(CrdsValue)),
        to_endpoints: *const std.ArrayList(*const EndPoint),
        max_chunk_bytes: usize,
    ) error{ SerializationError, OutOfMemory }!std.ArrayList(Packet) {
        var packets = try std.ArrayList(Packet).initCapacity(allocator, MAX_PACKETS_PER_PUSH);
        errdefer packets.deinit();

        var packet_buf: [PACKET_DATA_SIZE]u8 = undefined;
        var buf_byte_size: u64 = 0;

        var protocol_msg_values = std.ArrayList(CrdsValue).init(allocator);
        defer protocol_msg_values.deinit();

        for (to_crds_values.items, to_endpoints.items) |crds_values, to_endpoint| {
            const crds_value_len = crds_values.items.len;

            for (crds_values.items, 0..) |crds_value, i| {
                const data_byte_size = bincode.get_serialized_size_with_slice(&packet_buf, crds_value, bincode.Params{}) catch {
                    return error.SerializationError;
                };

                // should never have a chunk larger than the max
                if (data_byte_size > max_chunk_bytes) {
                    unreachable;
                }
                const new_chunk_size = buf_byte_size + data_byte_size;
                const is_last_iter = i == crds_value_len - 1;

                if (new_chunk_size > max_chunk_bytes or is_last_iter) {
                    // write message to packet
                    const protocol_message = switch (self) {
                        PacketBuilder.PullResponse => Protocol{ .PullResponse = .{ my_pubkey, protocol_msg_values.items } },
                        PacketBuilder.PushMessage => Protocol{ .PushMessage = .{ my_pubkey, protocol_msg_values.items } },
                    };
                    const packet_slice = bincode.writeToSlice(&packet_buf, protocol_message, bincode.Params{}) catch {
                        return error.SerializationError;
                    };
                    const packet = Packet.init(to_endpoint.*, packet_buf, packet_slice.len);
                    try packets.append(packet);

                    // reset array
                    buf_byte_size = data_byte_size;
                    protocol_msg_values.clearRetainingCapacity();
                    try protocol_msg_values.append(crds_value);
                } else {
                    // add it to the current chunk
                    buf_byte_size = new_chunk_size;
                    try protocol_msg_values.append(crds_value);
                }
            }
        }

        return packets;
    }
};

test "gossip.gossip_service: tests handle_prune_messages" {
    var rng = std.rand.DefaultPrng.init(91);

    const allocator = std.testing.allocator;
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    // add some peers
    var lg = gossip_service.crds_table_rw.write();
    for (0..10) |_| {
        var rand_keypair = try KeyPair.create(null);
        var value = try CrdsValue.random_with_index(rng.random(), &rand_keypair, 0); // contact info
        try lg.mut().insert(value, get_wallclock());
    }
    lg.unlock();

    // set the active set
    try gossip_service.rotate_active_set();

    var as_lg = gossip_service.active_set_rw.read();
    var as: *const ActiveSet = as_lg.get();
    try std.testing.expect(as.len > 0);
    var peer0 = as.peers[0];
    as_lg.unlock();

    var prunes = [_]Pubkey{Pubkey.random(rng.random(), .{})};
    var prune_data = PruneData{
        .pubkey = peer0,
        .destination = gossip_service.my_pubkey,
        .prunes = &prunes,
        .signature = undefined,
        .wallclock = get_wallclock(),
    };
    try prune_data.sign(&my_keypair);

    try gossip_service.handle_prune_message(&prune_data);

    var as_lg2 = gossip_service.active_set_rw.read();
    var as2: *const ActiveSet = as_lg2.get();
    try std.testing.expect(as2.pruned_peers.get(peer0).?.contains(&prunes[0].data));
    as_lg2.unlock();
}

test "gossip.gossip_service: tests handle_pull_response" {
    const allocator = std.testing.allocator;

    var rng = std.rand.DefaultPrng.init(91);
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    // get random values
    var crds_values: [5]CrdsValue = undefined;
    var kp = try KeyPair.create(null);
    for (0..5) |i| {
        var value = try CrdsValue.random_with_index(rng.random(), &kp, 0);
        value.data.LegacyContactInfo.id = Pubkey.random(rng.random(), .{});
        crds_values[i] = value;
    }

    try gossip_service.handle_pull_response(&crds_values, null);

    // make sure values are inserted
    var crds_table_lg = gossip_service.crds_table_rw.read();
    var crds_table: *const CrdsTable = crds_table_lg.get();
    for (crds_values) |value| {
        _ = crds_table.get(value.label()).?;
    }
    crds_table_lg.unlock();

    // try inserting again with same values (should all fail)
    try gossip_service.handle_pull_response(&crds_values, null);

    var lg = gossip_service.failed_pull_hashes_mux.lock();
    var failed_pull_hashes: *HashTimeQueue = lg.mut();
    try std.testing.expect(failed_pull_hashes.len() == 5);
    lg.unlock();
}

test "gossip.gossip_service: tests handle_pull_request" {
    const allocator = std.testing.allocator;

    var rng = std.rand.DefaultPrng.init(91);
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    // insert random values
    var crds_table_lg = gossip_service.crds_table_rw.write();
    var crds_table: *CrdsTable = crds_table_lg.mut();
    const N_FILTER_BITS = 1;

    var done = false;
    var count: usize = 0;
    while (!done) {
        count += 1;
        for (0..5) |_| {
            var value = try CrdsValue.random_with_index(rng.random(), &my_keypair, 0);
            value.data.LegacyContactInfo.id = Pubkey.random(rng.random(), .{});
            try crds_table.insert(value, get_wallclock());

            // make sure well get a response from the request
            const vers_value = crds_table.get(value.label()).?;
            const hash_bits = pull_request.hash_to_u64(&vers_value.value_hash) >> (64 - N_FILTER_BITS);
            if (hash_bits == 0) {
                done = true;
            }
        }

        if (count > 5) {
            @panic("something went wrong");
        }
    }
    crds_table_lg.unlock();

    const Bloom = @import("../bloom/bloom.zig").Bloom;
    // only consider the first bit so we know well get matches
    var bloom = try Bloom.random(allocator, 100, 0.1, N_FILTER_BITS);
    defer bloom.deinit();

    var ci_data = crds.CrdsData.random_from_index(rng.random(), 0);
    ci_data.LegacyContactInfo.id = my_pubkey;
    const crds_value = try CrdsValue.initSigned(ci_data, &my_keypair);

    const filter = CrdsFilter{
        .filter = bloom,
        .mask = (~@as(usize, 0)) >> N_FILTER_BITS,
        .mask_bits = N_FILTER_BITS,
    };
    const addr = SocketAddr.random(rng.random());

    var packets = try gossip_service.handle_pull_request(
        crds_value,
        filter,
        addr.toEndpoint(),
        null,
    );
    defer packets.deinit();

    try std.testing.expect(packets.items.len > 0);
}

test "gossip.gossip_service: test build prune messages and handle_push_msgs" {
    const allocator = std.testing.allocator;
    var rng = std.rand.DefaultPrng.init(91);
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    var push_from = Pubkey.random(rng.random(), .{});
    var values = std.ArrayList(CrdsValue).init(allocator);
    defer values.deinit();
    for (0..10) |_| {
        var value = try CrdsValue.random_with_index(rng.random(), &my_keypair, 0);
        value.data.LegacyContactInfo.id = Pubkey.random(rng.random(), .{});
        try values.append(value);
    }

    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();
    logger.spawn();

    // insert contact info to send prunes to
    var send_contact_info = crds.LegacyContactInfo.random(rng.random());
    send_contact_info.id = push_from;
    // valid socket addr
    var gossip_socket = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 20);
    send_contact_info.gossip = gossip_socket;

    var ci_value = try CrdsValue.initSigned(crds.CrdsData{
        .LegacyContactInfo = send_contact_info,
    }, &my_keypair);
    var lg = gossip_service.crds_table_rw.write();
    try lg.mut().insert(ci_value, get_wallclock());
    lg.unlock();

    var forigins = try gossip_service.handle_push_message(values.items);
    defer forigins.deinit();
    try std.testing.expect(forigins.keys().len == 0);

    var failed_origins = try gossip_service.handle_push_message(values.items);
    defer failed_origins.deinit();
    try std.testing.expect(failed_origins.keys().len > 0);

    var prune_packets = try gossip_service.build_prune_message(&failed_origins, push_from);
    defer prune_packets.deinit();

    var packet = prune_packets.items[0];
    var protocol_message = try bincode.readFromSlice(
        allocator,
        Protocol,
        packet.data[0..packet.size],
        bincode.Params.standard,
    );
    defer bincode.free(allocator, protocol_message);

    var msg = protocol_message.PruneMessage;
    var prune_data = msg[1];
    try std.testing.expect(prune_data.destination.equals(&push_from));
    try std.testing.expectEqual(prune_data.prunes.len, 10);
}

test "gossip.gossip_service: test build_pull_requests" {
    const allocator = std.testing.allocator;
    var rng = std.rand.DefaultPrng.init(91);
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();
    logger.spawn();

    // insert peers to send msgs to
    var keypair = try KeyPair.create([_]u8{1} ** 32);
    var lg = gossip_service.crds_table_rw.write();
    for (0..20) |_| {
        var value = try CrdsValue.random(rng.random(), &keypair);
        try lg.mut().insert(value, get_wallclock());
    }
    lg.unlock();

    var packets = try gossip_service.build_pull_requests(2);
    defer packets.deinit();

    try std.testing.expect(packets.items.len > 1);
    try std.testing.expect(!std.mem.eql(u8, &packets.items[0].data, &packets.items[1].data));
}

test "gossip.gossip_service: test build_push_messages" {
    const allocator = std.testing.allocator;
    var rng = std.rand.DefaultPrng.init(91);
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    // add some peers
    var lg = gossip_service.crds_table_rw.write();
    for (0..10) |_| {
        var keypair = try KeyPair.create(null);
        var value = try CrdsValue.random_with_index(rng.random(), &keypair, 0); // contact info
        try lg.mut().insert(value, get_wallclock());
    }
    lg.unlock();

    var keypair = try KeyPair.create([_]u8{1} ** 32);
    // var id = Pubkey.fromPublicKey(&keypair.public_key, false);
    var value = try CrdsValue.random(rng.random(), &keypair);

    // set the active set
    try gossip_service.rotate_active_set();
    {
        var aslg = gossip_service.active_set_rw.read();
        try std.testing.expect(aslg.get().len > 0);
        aslg.unlock();
    }

    {
        var pqlg = gossip_service.push_msg_queue_mux.lock();
        var push_queue = pqlg.mut();
        try push_queue.append(value);
        pqlg.unlock();
    }
    gossip_service.drain_push_queue_to_crds_table(get_wallclock());

    var clg = gossip_service.crds_table_rw.read();
    try std.testing.expect(clg.get().len() == 11);
    clg.unlock();

    var cursor: u64 = 0;
    var msgs = (try gossip_service.build_push_messages(&cursor)).?;
    try std.testing.expectEqual(cursor, 11);
    try std.testing.expect(msgs.items.len > 0);
    msgs.deinit();

    var msgs2 = try gossip_service.build_push_messages(&cursor);
    try std.testing.expectEqual(cursor, 11);
    try std.testing.expect(msgs2 == null);
}

test "gossip.gossip_service: test packet verification" {
    const allocator = std.testing.allocator;
    var exit = AtomicBool.init(false);
    var keypair = try KeyPair.create([_]u8{1} ** 32);
    var id = Pubkey.fromPublicKey(&keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(id);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(allocator, contact_info, keypair, &exit);
    defer gossip_service.deinit();

    var packet_channel = gossip_service.packet_channel;
    var verified_channel = gossip_service.verified_channel;

    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();
    logger.spawn();

    var packet_verifier_handle = try Thread.spawn(.{}, GossipService.verify_packets, .{ &gossip_service, logger });

    var rng = std.rand.DefaultPrng.init(get_wallclock());
    var data = crds.CrdsData.random_from_index(rng.random(), 0);
    data.LegacyContactInfo.id = id;
    data.LegacyContactInfo.wallclock = 0;
    var value = try CrdsValue.initSigned(data, &keypair);

    try std.testing.expect(try value.verify(id));

    var values = [_]crds.CrdsValue{value};
    const protocol_msg = Protocol{
        .PushMessage = .{ id, &values },
    };

    var peer = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);
    var from = peer.toEndpoint();

    var buf = [_]u8{0} ** PACKET_DATA_SIZE;
    var out = try bincode.writeToSlice(buf[0..], protocol_msg, bincode.Params{});
    var packet = Packet.init(from, buf, out.len);

    for (0..3) |_| {
        try packet_channel.send(packet);
    }

    // send one which fails sanitization
    var value_v2 = try CrdsValue.initSigned(crds.CrdsData.random_from_index(rng.random(), 2), &keypair);
    value_v2.data.EpochSlots[0] = crds.MAX_EPOCH_SLOTS;
    var values_v2 = [_]crds.CrdsValue{value_v2};
    const protocol_msg_v2 = Protocol{
        .PushMessage = .{ id, &values_v2 },
    };
    var buf_v2 = [_]u8{0} ** PACKET_DATA_SIZE;
    var out_v2 = try bincode.writeToSlice(buf_v2[0..], protocol_msg_v2, bincode.Params{});
    var packet_v2 = Packet.init(from, buf_v2, out_v2.len);
    try packet_channel.send(packet_v2);

    // send one with a incorrect signature
    var rand_keypair = try KeyPair.create([_]u8{3} ** 32);
    var value2 = try CrdsValue.initSigned(crds.CrdsData.random_from_index(rng.random(), 0), &rand_keypair);
    var values2 = [_]crds.CrdsValue{value2};
    const protocol_msg2 = Protocol{
        .PushMessage = .{ id, &values2 },
    };
    var buf2 = [_]u8{0} ** PACKET_DATA_SIZE;
    var out2 = try bincode.writeToSlice(buf2[0..], protocol_msg2, bincode.Params{});
    var packet2 = Packet.init(from, buf2, out2.len);
    try packet_channel.send(packet2);

    var msg_count: usize = 0;
    while (msg_count < 3) {
        if (try verified_channel.try_drain()) |msgs| {
            defer verified_channel.allocator.free(msgs);
            for (msgs) |msg| {
                defer bincode.free(gossip_service.allocator, msg);
                try std.testing.expect(msg.message.PushMessage[0].equals(&id));
                msg_count += 1;
            }
        }
        std.time.sleep(10);
    }

    var attempt_count: u16 = 0;

    while (packet_channel.buffer.private.v.items.len != 0) {
        std.time.sleep(std.time.ns_per_ms * 10);
        attempt_count += 1;
        if (attempt_count > 10) {
            try std.testing.expect(false);
        }
    }

    try std.testing.expect(packet_channel.buffer.private.v.items.len == 0);
    try std.testing.expect(verified_channel.buffer.private.v.items.len == 0);

    exit.store(true, std.atomic.Ordering.Unordered);
    packet_verifier_handle.join();
}

test "gossip.gossip_service: process contact_info push packet" {
    const allocator = std.testing.allocator;
    var exit = AtomicBool.init(false);
    var my_keypair = try KeyPair.create([_]u8{1} ** 32);
    var my_pubkey = Pubkey.fromPublicKey(&my_keypair.public_key, true);

    var contact_info = crds.LegacyContactInfo.default(my_pubkey);
    contact_info.gossip = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);

    var gossip_service = try GossipService.init(
        allocator,
        contact_info,
        my_keypair,
        &exit,
    );
    defer gossip_service.deinit();

    var verified_channel = gossip_service.verified_channel;
    var responder_channel = gossip_service.responder_channel;

    var logger = Logger.init(allocator, .debug);
    defer logger.deinit();
    logger.spawn();

    var kp = try KeyPair.create(null);
    var pk = Pubkey.fromPublicKey(&kp.public_key, false);

    var packet_handle = try Thread.spawn(
        .{},
        GossipService.process_messages,
        .{
            &gossip_service,
            logger,
        },
    );

    // send a push message
    var id = pk;

    // new contact info
    var legacy_contact_info = crds.LegacyContactInfo.default(id);
    var crds_data = crds.CrdsData{
        .LegacyContactInfo = legacy_contact_info,
    };
    var crds_value = try crds.CrdsValue.initSigned(crds_data, &kp);
    var values = [_]crds.CrdsValue{crds_value};
    const msg = Protocol{
        .PushMessage = .{ id, &values },
    };

    // packet
    const peer = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 8000).toEndpoint();
    const protocol_msg = ProtocolMessage{
        .from_endpoint = peer,
        .message = msg,
    };
    try verified_channel.send(protocol_msg);

    // ping
    const ping_msg = ProtocolMessage{
        .message = Protocol{
            .PingMessage = try Ping.init(.{0} ** 32, &kp),
        },
        .from_endpoint = peer,
    };
    try verified_channel.send(ping_msg);

    // correct insertion into table
    var buf2: [100]crds.CrdsVersionedValue = undefined;
    std.time.sleep(std.time.ns_per_s);

    {
        var lg = gossip_service.crds_table_rw.read();
        var res = lg.get().get_contact_infos(&buf2);
        try std.testing.expect(res.len == 1);
        lg.unlock();
    }

    const resp = (try responder_channel.try_drain()).?;
    defer responder_channel.allocator.free(resp);
    try std.testing.expect(resp.len == 1);

    exit.store(true, std.atomic.Ordering.Unordered);
    packet_handle.join();
}

test "gossip.gossip_service: init, exit, and deinit" {
    var gossip_address = SocketAddr.init_ipv4(.{ 127, 0, 0, 1 }, 0);
    var my_keypair = try KeyPair.create(null);
    var rng = std.rand.DefaultPrng.init(get_wallclock());
    var contact_info = crds.LegacyContactInfo.random(rng.random());
    contact_info.gossip = gossip_address;
    var exit = AtomicBool.init(false);
    var gossip_service = try GossipService.init(
        std.testing.allocator,
        contact_info,
        my_keypair,
        &exit,
    );

    var logger = Logger.init(std.testing.allocator, .debug);
    defer logger.deinit();
    logger.spawn();

    var handle = try std.Thread.spawn(
        .{},
        GossipService.run,
        .{ &gossip_service, logger },
    );

    exit.store(true, std.atomic.Ordering.Unordered);
    handle.join();
    gossip_service.deinit();
}

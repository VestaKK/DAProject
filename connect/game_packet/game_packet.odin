package game_package

import "core:encoding/cbor"
import "core:net"
import sa "core:container/small_array"

SEQUENCE_BUFFER_SIZE :: 1024
MAX_CONNECTIONS :: 4

Network :: struct {
    host_id: int,
    socket: net.UDP_Socket,
    channels: sa.Small_Array(MAX_CONNECTIONS, Channel)
}

Channel :: struct {
    queue: struct{},
    id: i8,
    color: Color,
    seq: u16,
    ack: u16,
    ack_bits: bit_set[1..=32; u32],
    endpoint: net.Endpoint,
}

Color :: enum u8 {
    Red,
    White,
    Blue,
}

@(private)
Header :: struct {
    color: Color,
    from: i8,
    seq: u16,
    ack: u16,
    ack_bits: bit_set[1..=32; u32],
}

Dummy :: struct {}
Marker :: struct {}

Message :: union {
    Dummy,
    Marker,
}

Packet :: struct {
    header: Header,
    message: Message,
}

init_network :: proc(network: ^Network, socket: net.UDP_Socket, host_endpoint: net.Endpoint) -> (host_id: int, ok: bool) {
    host_id = add_connection(network, host_endpoint) or_return
    network.host_id = host_id
    network.socket = socket
    return
}

add_connection :: proc(network: ^Network, endpoint: net.Endpoint) -> (channel_id: int, ok: bool) {
    new_id := network.channels.len
    new_channel := Channel{
        id = i8(new_id),
        color = .White,
        endpoint = endpoint,
    }
    sa.push_back(&network.channels, new_channel) or_return
    return new_id, true
}

broadcast_message :: proc(network: ^Network, message: Message, should_ack := false) -> net.UDP_Send_Error {
    for channel_id in 0..<sa.len(network.channels) {
        send_message(network, message, channel_id, should_ack) or_return
    }
    return nil
}

send_message :: proc(network: ^Network, message: Message, recipient_id: int, should_ack := false) -> net.UDP_Send_Error {
    channel := sa.get_ptr(&network.channels, recipient_id)

    packet: Packet
    packet.header.from = channel.id
    packet.header.color = channel.color
    packet.header.seq = channel.seq
    packet.header.ack = channel.ack
    packet.header.ack_bits = channel.ack_bits
    packet.message = message

    channel.seq += 1

    // put the packet in a sent sent_packet_buffer or something

    bytes, marshal_err := cbor.marshal_into_bytes(packet, cbor.ENCODE_SMALL)
    defer delete(bytes)

    bytes_written := net.send_udp(network.socket, bytes, channel.endpoint) or_return
    return nil
}

deserialise_packet :: proc(buf: []byte) -> Packet {
    packet: Packet
    cbor.unmarshal_from_string(transmute(string)buf, &packet)
    return packet
}

receive_packet :: proc(packet: Packet) {
    // chuck the packet into its relevant channel queue idk
}

sort_out_channel_queues :: proc(network: ^Network) {
}
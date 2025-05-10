package shared

import "core:net"

MAX_PLAYER_COUNT :: 4

Private_Profile :: struct {
    publc_endpoint: net.Endpoint,
    endpoint: net.Endpoint,
    assigned_id: i64,
    user_name: string,
}

Create_Lobby_Packet :: struct {
    lobby_id: i64,
    lobby_name: string,
    host_name: string,
    host_endpoint: net.Endpoint,
    load_required: bool,
}

Join_Lobby_Packet :: struct {
    lobby_id: i64,
    join_name: string,
    join_endpoint: net.Endpoint,
}

Start_Lobby_Packet :: struct {
    lobby_id: i64,
    host_id: i64,
}

Leave_Lobby_Packet :: struct {
    lobby_id: i64,
    assigned_id: i64,
}

Packet :: union {
    Create_Lobby_Packet,
    Join_Lobby_Packet,
    Leave_Lobby_Packet,
    Start_Lobby_Packet,
}

Create_Response :: struct {
    assigned_id: i64,
}

Join_Lobby_Response :: struct {
    assigned_id: i64,
    lobby_name: string,
    host_name: string,
    load_required: bool,
}

Leave_Lobby_Response :: struct {}


Start_Lobby_Response :: struct {
    host: Private_Profile,
    players: []Private_Profile,
}

Error :: string

Response :: union {
    Error,
    Create_Response,
    Join_Lobby_Response,
    Leave_Lobby_Response,
    Start_Lobby_Response,
}


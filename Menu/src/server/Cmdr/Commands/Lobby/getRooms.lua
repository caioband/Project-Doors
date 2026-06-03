return {
    Name = "getRooms",
    Description = "Gets a list of available rooms.",
    Group = "Lobby",
    Args = {
        {
            Type = "string",
            Name = "Filter",
            Description = "A string to filter room names by (optional).",
            Optional = true,
        }
    },
}
return {
    Name = "createRoom";
    Aliases = { "criarSala" };
    Description = "Creates a lobby room for the player running the command.";
    Group = "Lobby";
    Args = {
        {
            Type = "string";
            Name = "name";
            Description = "The room name.";
            Optional = true;
        },
        {
            Type = "integer";
            Name = "maxPlayers";
            Description = "Maximum players allowed in the room.";
            Optional = true;
        },
        {
            Type = "boolean";
            Name = "isPrivate";
            Description = "Whether the room should be private.";
            Optional = true;
        },
        {
            Type = "string";
            Name = "accessCode";
            Description = "Optional access code for private rooms.";
            Optional = true;
        },
    };
}
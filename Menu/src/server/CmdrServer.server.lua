local ReplicatedStorage = game:GetService("ReplicatedStorage")

local externalPackages = ReplicatedStorage:WaitForChild("ExternalPackages")
local cmdr = require(externalPackages:WaitForChild("cmdr"))

local cmdrFolder = script.Parent:WaitForChild("Cmdr")
local commandsFolder = cmdrFolder:WaitForChild("Commands")

cmdr:RegisterCommandsIn(commandsFolder)
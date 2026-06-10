return {
	Name = "chooseComponent",
	Description = "Tests the ChooseComponent module",
	Group = "DefaultAdmin",

	Args = {
		{
			Type = "string",
			Name = "type",
			Description = "Type of component to choose",
		},
        {
			Type = "number",
			Name = "delay",
			Description = "Delay before the component is removed",
            Optional = true,
		}
	},

	ClientRun = function(context, type, delay)
		local ChooseComponent = require(game.ReplicatedStorage.Shared:WaitForChild("SharedModules"):WaitForChild("ChooseComponent"))
        
        ChooseComponent:Show({
            type = type,
            content = "This is a test of the ChooseComponent module.",
            confirmText = "Confirm",
            cancelText = "Cancel",
            confirmCallback = function()
                print("Confirmed!")
            end,
            cancelCallback = function()
                print("Cancelled!")
            end,
            delay = delay,
        })

        return true
    end,
}
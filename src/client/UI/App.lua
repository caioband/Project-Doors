local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Roact = require(Packages:WaitForChild("Roact"))

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local App = Roact.Component:extend("App")

function App:render()
	local uiConfig = Config.Ui

	return Roact.createElement("ScreenGui", {
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
	}, {
		Root = Roact.createElement("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(420, 220),
			BackgroundColor3 = uiConfig.CardColor,
			BorderSizePixel = 0,
		}, {
			Corner = Roact.createElement("UICorner", {
				CornerRadius = UDim.new(0, 18),
			}),
			Stroke = Roact.createElement("UIStroke", {
				Color = uiConfig.AccentColor,
				Thickness = 2,
				Transparency = 0.15,
			}),
			Padding = Roact.createElement("UIPadding", {
				PaddingTop = UDim.new(0, 24),
				PaddingBottom = UDim.new(0, 24),
				PaddingLeft = UDim.new(0, 24),
				PaddingRight = UDim.new(0, 24),
			}),
			Background = Roact.createElement("Frame", {
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = uiConfig.BackgroundColor,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				ZIndex = 0,
			}, {
				Corner = Roact.createElement("UICorner", {
					CornerRadius = UDim.new(0, 18),
				}),
			}),
			Title = Roact.createElement("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, 0),
				Size = UDim2.new(1, 0, 0, 52),
				Font = Enum.Font.GothamBold,
				Text = uiConfig.Title,
				TextColor3 = uiConfig.TextColor,
				TextSize = 28,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Subtitle = Roact.createElement("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(0, 58),
				Size = UDim2.new(1, 0, 0, 42),
				Font = Enum.Font.Gotham,
				Text = uiConfig.Subtitle,
				TextColor3 = uiConfig.MutedTextColor,
				TextSize = 18,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			AccentBar = Roact.createElement("Frame", {
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, 0, 1, 0),
				Size = UDim2.new(0.45, 0, 0, 8),
				BackgroundColor3 = uiConfig.AccentColor,
				BorderSizePixel = 0,
			}, {
				Corner = Roact.createElement("UICorner", {
					CornerRadius = UDim.new(1, 0),
				}),
			}),
		}),
	})
end

return App
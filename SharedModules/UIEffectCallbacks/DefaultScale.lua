local TweenService = game:GetService("TweenService")

local HOVER_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_SCALE = 1.04
local PRESSED_SCALE = 0.98

local activeTweens = setmetatable({}, { __mode = "k" })

local function ensureScale(button)
	local uiScale = button:FindFirstChild("UIEffectHoverScale")
	if uiScale and uiScale:IsA("UIScale") then
		return uiScale
	end

	uiScale = Instance.new("UIScale")
	uiScale.Name = "UIEffectHoverScale"
	uiScale.Scale = 1
	uiScale.Parent = button

	return uiScale
end

local function playScaleTween(button, scale, tweenInfo)
	local uiScale = ensureScale(button)
	local activeTween = activeTweens[button]
	if activeTween then
		activeTween:Cancel()
	end

	local tween = TweenService:Create(uiScale, tweenInfo, {
		Scale = scale,
	})
	activeTweens[button] = tween
	tween:Play()
end

return {
	MouseEnter = function(guiButton)
		playScaleTween(guiButton, HOVER_SCALE, HOVER_TWEEN_INFO)
	end,
	MouseLeave = function(guiButton)
		playScaleTween(guiButton, 1, HOVER_TWEEN_INFO)
	end,
	MouseButton1Down = function(guiButton)
		playScaleTween(guiButton, PRESSED_SCALE, PRESS_TWEEN_INFO)
	end,
	MouseButton1Up = function(guiButton)
		playScaleTween(guiButton, HOVER_SCALE, PRESS_TWEEN_INFO)
	end,
	Activated = function(guiButton)
		playScaleTween(guiButton, 1, HOVER_TWEEN_INFO)
	end,
	Default = function(guiButton)
		playScaleTween(guiButton, 1, HOVER_TWEEN_INFO)
	end,
}
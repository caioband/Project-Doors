local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Loading = script.Parent.Parent:WaitForChild("Loading")

local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DOT_ENABLED_COLOR = Color3.fromRGB(255, 221, 87)
local DOT_RAISE_OFFSET_SCALE = 0.035
local DOT_TWEEN_INFO = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)


local Packages = ReplicatedStorage:WaitForChild("ExternalPackages")
local Promise = require(Packages.promise)
local LoadingScreen = {}
LoadingScreen.__index = LoadingScreen
LoadingScreen.DotsAnimating = false
LoadingScreen._activeDotTweenCount = 0
LoadingScreen._dotTweens = {}

function LoadingScreen:_setDotsAnimatingState(isAnimating: boolean)
	self.DotsAnimating = isAnimating
end

function LoadingScreen:_trackDotTween(dot: Frame, tween: Tween)
	local existingTweenState = self._dotTweens[dot]
	if existingTweenState then
		if existingTweenState.Connection then
			existingTweenState.Connection:Disconnect()
		end

		if existingTweenState.IsActive then
			self._activeDotTweenCount = math.max(0, self._activeDotTweenCount - 1)
		end

		existingTweenState.Tween:Cancel()
	end

	self._activeDotTweenCount += 1
	self:_setDotsAnimatingState(true)

	local tweenState = {
		Tween = tween,
		IsActive = true,
	}

	tweenState.Connection = tween.Completed:Connect(function()
		if not tweenState.IsActive then
			return
		end

		tweenState.IsActive = false
		self._activeDotTweenCount = math.max(0, self._activeDotTweenCount - 1)
		self._dotTweens[dot] = nil
		self:_setDotsAnimatingState(self._activeDotTweenCount > 0)
		if tweenState.Connection then
			tweenState.Connection:Disconnect()
		end
	end)

	self._dotTweens[dot] = tweenState
end

function LoadingScreen:_getDotContainer()
	return Loading:WaitForChild("Load"):WaitForChild("DotLoadingTemplate")
end

function LoadingScreen:_getDotFrame(index: number)
	return self:_getDotContainer():FindFirstChild("DotLoading" .. index)
end

function LoadingScreen:_storeDotDefaults(dot: Frame, overwrite: boolean?)
	if overwrite or dot:GetAttribute("OriginalPosXScale") == nil then
		dot:SetAttribute("OriginalPosXScale", dot.Position.X.Scale)
		dot:SetAttribute("OriginalPosXOffset", dot.Position.X.Offset)
		dot:SetAttribute("OriginalPosYScale", dot.Position.Y.Scale)
		dot:SetAttribute("OriginalPosYOffset", dot.Position.Y.Offset)
		dot:SetAttribute("OriginalColorR", dot.BackgroundColor3.R)
		dot:SetAttribute("OriginalColorG", dot.BackgroundColor3.G)
		dot:SetAttribute("OriginalColorB", dot.BackgroundColor3.B)
	end
end

function LoadingScreen:_buildOriginalPosition(dot: Frame)
	return UDim2.new(
		dot:GetAttribute("OriginalPosXScale") or dot.Position.X.Scale,
		dot:GetAttribute("OriginalPosXOffset") or dot.Position.X.Offset,
		dot:GetAttribute("OriginalPosYScale") or dot.Position.Y.Scale,
		dot:GetAttribute("OriginalPosYOffset") or dot.Position.Y.Offset
	)
end

function LoadingScreen:_buildOriginalColor(dot: Frame)
	return Color3.new(
		dot:GetAttribute("OriginalColorR") or dot.BackgroundColor3.R,
		dot:GetAttribute("OriginalColorG") or dot.BackgroundColor3.G,
		dot:GetAttribute("OriginalColorB") or dot.BackgroundColor3.B
	)
end

function LoadingScreen:_animateDot(dot: Frame, state: string)
	self:_storeDotDefaults(dot)

	local originalPosition = self:_buildOriginalPosition(dot)
	local targetPosition = originalPosition
	local targetColor = self:_buildOriginalColor(dot)

	if state == "On" then
		targetPosition = UDim2.new(
			originalPosition.X.Scale,
			originalPosition.X.Offset,
			originalPosition.Y.Scale - DOT_RAISE_OFFSET_SCALE,
			originalPosition.Y.Offset
		)
		targetColor = DOT_ENABLED_COLOR
	end

	local tween = TweenService:Create(dot, DOT_TWEEN_INFO, {
		Position = targetPosition,
		BackgroundColor3 = targetColor,
	})

	self:_trackDotTween(dot, tween)
	tween:Play()
end

function LoadingScreen:CreateLoadingDots(number: number, spacingScale: number?)
	local dotTemplate = Loading:WaitForChild("Load"):WaitForChild("DotLoadingTemplate"):WaitForChild("Frame")
	local iterationTarget = math.max(1, number)
	spacingScale = spacingScale or 0.1

	if iterationTarget % 2 == 0 then
		iterationTarget += 1
	end

	for _, child in dotTemplate.Parent:GetChildren() do
		if child ~= dotTemplate and child.Name:match("^DotLoading%d+$") then
			child:Destroy()
		end
	end

	local middleIndex = math.ceil(iterationTarget / 2)

	dotTemplate.Name = "DotLoading" .. middleIndex
	dotTemplate.AnchorPoint = Vector2.new(0.5, 0.5)
	dotTemplate.Position = UDim2.fromScale(0.5, 0.5)
	dotTemplate.Visible = true
	self:_storeDotDefaults(dotTemplate, true)
    
	for i = 1, iterationTarget do
		if i ~= middleIndex then
			local dotClone = dotTemplate:Clone()
			dotClone.Name = "DotLoading" .. i
			dotClone.AnchorPoint = Vector2.new(0.5, 0.5)
			dotClone.Position = UDim2.fromScale(0.5 + ((i - middleIndex) * (2 * (spacingScale / number))), 0.5)
			dotClone.Parent = dotTemplate.Parent
			dotClone.Visible = true
			self:_storeDotDefaults(dotClone, true)
		end
	end
end

function LoadingScreen:GetTotalDots()
    local count = 0
    for _, child in self:_getDotContainer():GetChildren() do
        if child.Name:match("^DotLoading%d+$") then
            count += 1
        end
    end
    return count
end

function LoadingScreen:ResetDots()
    local dotContainer = self:_getDotContainer()
    local dotTemplate = dotContainer:GetChildren()[1]:Clone()
    dotTemplate.Name = "Frame"
    for _, child in dotContainer:GetChildren() do
        if child.Name:match("^DotLoading%d+$") then
            child:Destroy()
        end
    end
    dotTemplate.Parent = dotContainer
    dotTemplate.Visible = false
    dotTemplate.Position = UDim2.fromScale(0.5, 0.5)
    dotTemplate.BackgroundColor3 = self:_buildOriginalColor(dotTemplate)
end

function LoadingScreen:ClearDots()
    local dotContainer = self:_getDotContainer()
    for _, child in dotContainer:GetChildren() do
        if child.Name:match("^DotLoading%d+$") then
            child:Destroy()
        end
    end
end

function LoadingScreen:SetDotState(index: number, state: string)
	local dot = self:_getDotFrame(index)
	if not dot then
		return false
	end

	if state ~= "On" and state ~= "Off" then
		error("Invalid dot state: " .. tostring(state))
	end

	self:_animateDot(dot, state)
	return true
end

function LoadingScreen:SetCurrentStepText(message: string)
    local currentStepLabel = Loading:WaitForChild("Load"):WaitForChild("CurrentStep"):WaitForChild("Step")
    currentStepLabel.Text = message
end

function LoadingScreen:SetProgressionText(message: string)
    local progressionLabel = Loading:WaitForChild("Load"):WaitForChild("AdditionalInfo")
    progressionLabel.Text = message
end

function LoadingScreen:LoadFinished()

	local function TweenDescendantsAsync(guiObject: GuiObject)
		local tweenInfo = TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local function tweenGuiObject(target: GuiObject)
			local tweenProperties = {
				BackgroundTransparency = 1,
			}

			if target:IsA("TextLabel") or target:IsA("TextButton") or target:IsA("TextBox") then
				tweenProperties.TextTransparency = 1
				tweenProperties.TextStrokeTransparency = 1
			end

			if target:IsA("ImageLabel") or target:IsA("ImageButton") then
				tweenProperties.ImageTransparency = 1
			end

			TweenService:Create(target, tweenInfo, tweenProperties):Play()
		end

		tweenGuiObject(guiObject)

		for _, descendant in guiObject:GetDescendants() do
			if descendant:IsA("GuiObject") then
				tweenGuiObject(descendant)
			end
		end
	end

    local function CreditsLoop(Parent,CurrentStep: number)
		return Promise.new(function(resolve)
			if Parent:FindFirstChild("Step"..CurrentStep) then
            	local Credit = Parent:FindFirstChild("Step"..CurrentStep)
            	Credit.Visible = true
            	Credit.ImageTransparency = 1
            	local tweenInfo = TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
            	local T = TweenService:Create(Credit, tweenInfo, {
            	    ImageTransparency = 0,
            	})
            	T:Play()
            	T.Completed:Connect(function()
            	    Credit.Visible = false
            	    CurrentStep += 1
            	    task.wait(1)
				    CreditsLoop(Parent, CurrentStep):andThen(resolve)
            	end)
			else
				resolve()
        	end
		end)       
    end

    local Main = Loading:WaitForChild("Load"):WaitForChild("CurrentStep"):WaitForChild("Initializing")
    local currentStepLabel = Loading:WaitForChild("Load"):WaitForChild("CurrentStep"):WaitForChild("Step")
    local CreditsAndWarning = Loading:WaitForChild("CreditsAndWarning")
    Main.Text = "Loading Finished!"
    Main.Position = UDim2.fromScale(0.5, Main.Position.Y.Scale)
    currentStepLabel.Visible = false
    CreditsAndWarning.Visible = true
    TweenDescendantsAsync(Main.Parent.Parent)

    task.delay(2, function()

        local CurrentStep = 1
		local CurrentCamera = workspace.CurrentCamera
		CurrentCamera.CameraType = Enum.CameraType.Scriptable
        self:ClearDots()
        CreditsLoop(CreditsAndWarning, CurrentStep):await()
		CurrentCamera.CFrame = workspace:WaitForChild("Cameras"):WaitForChild("Menu").CFrame
		CurrentCamera.FieldOfView = 55
		ReplicatedFirst:SetAttribute("Loaded", true)
		self:Disable()
    end)
end

function LoadingScreen:Enable()
    Loading.Parent = PlayerGui
    Loading.Enabled = true
end

function LoadingScreen:Disable()
    Loading.Parent = ReplicatedFirst
    Loading.Enabled = false
end

return LoadingScreen

local TweenService = game:GetService("TweenService")

local OriginalColor = {}

return {
    
    MouseEnter = function (guiObject)

        if guiObject:IsA("ImageButton") then
            if not OriginalColor[guiObject] then
                 OriginalColor[guiObject] = guiObject.ImageColor3
            end
            TweenService:Create(guiObject, TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {ImageColor3 = Color3.fromRGB(255, 255, 255)}):Play()
        else
            if not OriginalColor[guiObject] then
                 OriginalColor[guiObject] = guiObject.BackgroundColor3
            end
            TweenService:Create(guiObject, TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = Color3.fromRGB(255, 255, 255)}):Play()
        end

    end,

    MouseLeave = function (guiObject)
        if guiObject:IsA("ImageButton") then
            if OriginalColor[guiObject] then
                 TweenService:Create(guiObject, TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {ImageColor3 = OriginalColor[guiObject]}):Play()
            end
        else
            if OriginalColor[guiObject]  then
                 TweenService:Create(guiObject, TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3 = OriginalColor[guiObject]}):Play()
            end
        end
    end
}
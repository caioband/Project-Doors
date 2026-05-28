local ContentProvider = game:GetService("ContentProvider")

local LoadingController = {}
LoadingController.__index = LoadingController

local TYPE_ORDER = {
	"Images",
	"Audio",
	"Textures",
	"Models",
	"Animations",
	"Meshes",
	"Gui",
	"Instances",
	"AssetIds",
	"Unknown",
}

local function classifyAsset(asset)
	if typeof(asset) == "string" then
		return "AssetIds"
	end

	if typeof(asset) ~= "Instance" then
		return "Unknown"
	end

	if asset:IsA("ImageLabel") or asset:IsA("ImageButton") or asset:IsA("ImageHandleAdornment") then
		return "Images"
	end

	if asset:IsA("Sound") then
		return "Audio"
	end

	if asset:IsA("Decal") or asset:IsA("Texture") or asset:IsA("SurfaceAppearance") then
		return "Textures"
	end

	if asset:IsA("Model") then
		return "Models"
	end

	if asset:IsA("Animation") then
		return "Animations"
	end

	if asset:IsA("MeshPart") or asset:IsA("SpecialMesh") then
		return "Meshes"
	end

	if asset:IsA("ScreenGui") or asset:IsA("GuiObject") then
		return "Gui"
	end

	return "Instances"
end

function LoadingController.new()
	local preloadStartedEvent = Instance.new("BindableEvent")
	local preloadFinishedEvent = Instance.new("BindableEvent")
	local sectionStartedEvent = Instance.new("BindableEvent")
	local sectionAssetLoadedEvent = Instance.new("BindableEvent")

	return setmetatable({
		AssetsToPreload = {},
		AssetsByType = {},
		AssetSections = {},
		_PreloadStartedEvent = preloadStartedEvent,
		PreloadStarted = preloadStartedEvent.Event,
		_PreloadFinishedEvent = preloadFinishedEvent,
		PreloadFinished = preloadFinishedEvent.Event,
		_SectionStartedEvent = sectionStartedEvent,
		SectionStarted = sectionStartedEvent.Event,
		_SectionAssetLoadedEvent = sectionAssetLoadedEvent,
		SectionAssetLoaded = sectionAssetLoadedEvent.Event,
	}, LoadingController)
end

function LoadingController:SetAssetsToPreload(assets)
	self.AssetsToPreload = {}

	if assets == nil then
		return self.AssetsToPreload
	end

	if typeof(assets) == "table" then
		for _, asset in ipairs(assets) do
			table.insert(self.AssetsToPreload, asset)
		end
	else
		table.insert(self.AssetsToPreload, assets)
	end

	return self.AssetsToPreload
end

function LoadingController:AddAssetsToPreload(assets)
	if assets == nil then
		return self.AssetsToPreload
	end

	if typeof(assets) == "table" then
		for _, asset in ipairs(assets) do
			table.insert(self.AssetsToPreload, asset)
		end
	else
		table.insert(self.AssetsToPreload, assets)
	end

	return self.AssetsToPreload
end

function LoadingController:_onPreloadStarted(totalAssets)
	if self._PreloadStartedEvent then
		self._PreloadStartedEvent:Fire(totalAssets)
	end
end

function LoadingController:_onPreloadFinished(totalAssets)
	if self._PreloadFinishedEvent then
		self._PreloadFinishedEvent:Fire(totalAssets)
	end
end

function LoadingController:BuildAssetSections()
	local assetsByType = {}
	local assetSections = {}

	for _, typeName in ipairs(TYPE_ORDER) do
		assetsByType[typeName] = {}
	end

	for _, asset in ipairs(self.AssetsToPreload) do
		local typeName = classifyAsset(asset)
		table.insert(assetsByType[typeName], asset)
	end

	for _, typeName in ipairs(TYPE_ORDER) do
		local assets = assetsByType[typeName]
		if #assets > 0 then
			table.insert(assetSections, {
				Type = typeName,
				Assets = assets,
			})
		end
	end

	self.AssetsByType = assetsByType
	self.AssetSections = assetSections

	return assetSections
	end

function LoadingController:_onSectionStart(section, sectionIndex, sectionCount)
	if self._SectionStartedEvent then
		self._SectionStartedEvent:Fire(section.Type, section.Assets, sectionIndex, sectionCount)
	end
end

function LoadingController:_onSectionAssetLoaded(section, sectionIndex, sectionCount, assetIndex, sectionAssetCount, assetId, assetFetchStatus)
	if self._SectionAssetLoadedEvent then
		self._SectionAssetLoadedEvent:Fire(
			section.Type,
			assetIndex,
			sectionAssetCount,
			sectionIndex,
			sectionCount,
			assetId,
			assetFetchStatus
		)
	end
end

function LoadingController:Destroy()
	if self._PreloadStartedEvent then
		self._PreloadStartedEvent:Destroy()
		self._PreloadStartedEvent = nil
		self.PreloadStarted = nil
	end

	if self._PreloadFinishedEvent then
		self._PreloadFinishedEvent:Destroy()
		self._PreloadFinishedEvent = nil
		self.PreloadFinished = nil
	end

	if self._SectionStartedEvent then
		self._SectionStartedEvent:Destroy()
		self._SectionStartedEvent = nil
		self.SectionStarted = nil
	end

	if self._SectionAssetLoadedEvent then
		self._SectionAssetLoadedEvent:Destroy()
		self._SectionAssetLoadedEvent = nil
		self.SectionAssetLoaded = nil
	end
end

function LoadingController:PreloadAssets()
	if #self.AssetsToPreload == 0 then
		return
	end

	local assetSections = self:BuildAssetSections()
	self:_onPreloadStarted(#self.AssetsToPreload)

	for sectionIndex, section in ipairs(assetSections) do
		local sectionAssetCount = #section.Assets

		self:_onSectionStart(section, sectionIndex, #assetSections)

		for assetIndex, asset in ipairs(section.Assets) do
			local assetId = asset
			local assetFetchStatus = Enum.AssetFetchStatus.Success

			ContentProvider:PreloadAsync({ asset }, function(callbackAssetId, callbackAssetFetchStatus)
				assetId = callbackAssetId
				assetFetchStatus = callbackAssetFetchStatus
			end)

			self:_onSectionAssetLoaded(
				section,
				sectionIndex,
				#assetSections,
				assetIndex,
				sectionAssetCount,
				assetId,
				assetFetchStatus
			)
		end
	end
end



function LoadingController:Start()

	self:PreloadAssets()

	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	task.wait(0.2)
	self:_onPreloadFinished(#self.AssetsToPreload)
end

return LoadingController
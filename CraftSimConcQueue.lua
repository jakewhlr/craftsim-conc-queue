---@class CraftSimConcQueue
local CraftSimConcQueue = {}
local CraftSim = CraftSimAPI.GetCraftSim()
local GGUI = CraftSim.GGUI
local GUTIL = CraftSim.GUTIL

-- Initialize the addon
function CraftSimConcQueue:Init()
    if CraftSim.RECIPE_SCAN and CraftSim.RECIPE_SCAN.UI and CraftSim.RECIPE_SCAN.UI.InitRecipeScanTab then
        local originalInitRecipeScanTab = CraftSim.RECIPE_SCAN.UI.InitRecipeScanTab
        CraftSim.RECIPE_SCAN.UI.InitRecipeScanTab = function(recipeScanTab)
            originalInitRecipeScanTab(recipeScanTab)
            CraftSimConcQueue:AddConcentrationButtons(recipeScanTab)
        end
    end

    if CraftSim.RECIPE_SCAN and CraftSim.RECIPE_SCAN.frame then
        C_Timer.After(2, function()
            if CraftSim.RECIPE_SCAN.frame and CraftSim.RECIPE_SCAN.frame.content and CraftSim.RECIPE_SCAN.frame.content.recipeScanTab then
                CraftSimConcQueue:AddConcentrationButtons(CraftSim.RECIPE_SCAN.frame.content.recipeScanTab)
            end
        end)
    end

    -- Add the concentration queue functions to CraftSim.RECIPE_SCAN
    if CraftSim.RECIPE_SCAN then
        CraftSim.RECIPE_SCAN.QueueConcentrationCrafts = CraftSimConcQueue.QueueConcentrationCrafts
        CraftSim.RECIPE_SCAN.QueueAllScannedProfessions = CraftSimConcQueue.QueueAllScannedProfessions

        -- Hook into CraftSim's UpdateScanProfessionsButtons to hide/show our button
        local originalUpdateScanProfessionsButtons = CraftSim.RECIPE_SCAN.UpdateScanProfessionsButtons
        CraftSim.RECIPE_SCAN.UpdateScanProfessionsButtons = function(self)
            originalUpdateScanProfessionsButtons(self)
            CraftSimConcQueue:UpdateButtonVisibility()
        end
    end
end

-- Add the concentration queue buttons to the Recipe Scan UI
function CraftSimConcQueue:AddConcentrationButtons(recipeScanTab)
    local content = recipeScanTab.content
    if not content or content.queueConcentrationCraftsButton then
        return
    end

    -- Queue C. Crafts button
    content.queueConcentrationCraftsButton = GGUI.Button {
        parent = content,
        sizeX = 170,
        anchorPoints = { { anchorParent = content.sendToCraftQueueButton.frame, anchorA = "BOTTOM", anchorB = "TOP", offsetY = 5 } },
        label = "Queue C. Crafts",
        initialStatusID = "Ready",
        clickCallback = function()
            local professionList = CraftSim.RECIPE_SCAN.frame.content.recipeScanTab.content.professionList
            local selectedRow = professionList.selectedRow

            if selectedRow and selectedRow.currentResults and #selectedRow.currentResults > 0 then
                CraftSimConcQueue.QueueConcentrationCrafts(selectedRow.currentResults)
            end
        end
    }

    content.queueConcentrationCraftsButton:SetStatusList {
        {
            statusID = "Ready",
            label = "Queue C. Crafts",
            enabled = true,
        }
    }

    content.queueAllConcentrationCraftsButton = GGUI.Button {
        parent = content, anchorParent = content.scanProfessionsButton.frame, anchorA = "LEFT", anchorB = "RIGHT",
        label = "Queue C. Crafts", offsetX = 5, adjustWidth = true, sizeX = 15,
        clickCallback = function()
            CraftSimConcQueue.QueueAllScannedProfessions()
        end
    }
end

-- Update button visibility based on CraftSim's scanning state
function CraftSimConcQueue:UpdateButtonVisibility()
    local content = CraftSim.RECIPE_SCAN.frame and CraftSim.RECIPE_SCAN.frame.content and
        CraftSim.RECIPE_SCAN.frame.content.recipeScanTab and
        CraftSim.RECIPE_SCAN.frame.content.recipeScanTab.content

    if not content or not content.queueAllConcentrationCraftsButton then
        return
    end

    -- Hide our button when CraftSim is scanning to avoid overlap with Cancel button
    if CraftSim.RECIPE_SCAN.isScanningProfessions then
        content.queueAllConcentrationCraftsButton:Hide()
    else
        content.queueAllConcentrationCraftsButton:Show()
    end
end

function CraftSimConcQueue.QueueConcentrationCrafts(recipeScanResults)
    local concentrationRecipes = {}
    for _, recipeData in ipairs(recipeScanResults) do
        local concentrationValue = recipeData:GetConcentrationValue() or 0
        if concentrationValue > 0 then
            table.insert(concentrationRecipes, recipeData)
        end
    end

    if #concentrationRecipes == 0 then
        return
    end

    -- Sort by highest concentration value (gold per concentration point)
    table.sort(concentrationRecipes, function(a, b)
        local aValue = a:GetConcentrationValue() or 0
        local bValue = b:GetConcentrationValue() or 0
        return aValue > bValue
    end)

    -- Get current concentration available from CraftSim's ConcentrationTracker
    local totalConcentrationBudget = 1000 -- fallback
    local concentrationData = CraftSim.CONCENTRATION_TRACKER:GetCurrentConcentrationData()
    if concentrationData then
        totalConcentrationBudget = math.floor(concentrationData:GetCurrentAmount())
    end
    local usedConcentration = 0
    local recipesToQueue = {}

    for i, recipeData in ipairs(concentrationRecipes) do
        local concentrationCost = recipeData.concentrationCost or 0
        local concentrationValue = recipeData:GetConcentrationValue() or 0
        local recipeName = recipeData.recipeName or "Unknown Recipe"
        local professionName = recipeData.professionData.professionInfo.professionName or "Unknown Profession"

        if concentrationCost > 0 then
            -- Get ingenuity stats for breakthrough calculation
            local ingenuityChance = recipeData.professionStats.ingenuity:GetPercent(true)
            local ingenuityRefund = 0.5 + recipeData.professionStats.ingenuity:GetExtraValue()

            -- Calculate effective concentration cost per craft (accounting for ingenuity)
            local averageConcentrationPerCraft = concentrationCost * (1 - (ingenuityChance * ingenuityRefund))

            -- Calculate how many copies we can afford with ingenuity factored in
            local remainingBudget = totalConcentrationBudget - usedConcentration
            local totalCopies = math.floor(remainingBudget / averageConcentrationPerCraft)

            if totalCopies > 0 then
                -- Calculate actual concentration that will be used on average
                local actualConcentrationUsed = totalCopies * averageConcentrationPerCraft
                local expectedProcs = totalCopies * ingenuityChance

                usedConcentration = usedConcentration + actualConcentrationUsed

                table.insert(recipesToQueue, {
                    recipeData = recipeData,
                    amount = totalCopies,
                    concentrationCost = concentrationCost,
                    concentrationValue = concentrationValue,
                    totalConcentrationCost = actualConcentrationUsed
                })

                -- Actually add the recipe to the craft queue
                CraftSim.CRAFTQ:AddRecipe { recipeData = recipeData, amount = totalCopies }
            end
        end
    end
end

-- Queue concentration crafts for all profession rows that have scan results
function CraftSimConcQueue.QueueAllScannedProfessions()
    local professionList = CraftSim.RECIPE_SCAN.frame.content.recipeScanTab.content.professionList
    local activeRows = professionList.activeRows

    if #activeRows <= 0 then
        return
    end

    for _, row in ipairs(activeRows) do
        local checkBoxColumn = row.columns[1]
        if checkBoxColumn.checkbox:GetChecked() and row.currentResults and #row.currentResults > 0 then
            CraftSimConcQueue.QueueConcentrationCrafts(row.currentResults)
        end
    end
end

CraftSimConcQueue:Init()

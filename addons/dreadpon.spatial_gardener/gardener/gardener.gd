tool
extends Spatial


#-------------------------------------------------------------------------------
# Manages the lifecycles and connection of all components:
# Greenhouse plants, Toolshed brushes, Painter controller
# And the Arborist plant placement manager
#
# A lot of these connections go through the Gardener
# Because some signal receivers need additional data the signal senders don't know about
# E.g. painter doesn't know about plant states, but arborist needs them to apply painting changes
#-------------------------------------------------------------------------------


const FunLib = preload("../utility/fun_lib.gd")
const Logger = preload("../utility/logger.gd")
const Defaults = preload("../utility/defaults.gd")
const Greenhouse = preload("../greenhouse/greenhouse.gd")
const Toolshed = preload("../toolshed/toolshed.gd")
const Painter = preload("painter.gd")
const Arborist = preload("../arborist/arborist.gd")
const DebugViewer = preload("debug_viewer.gd")
const UI_SidePanel = preload("../controls/ui_side_panel.gd")
const Globals = preload("../utility/globals.gd")

const PropAction = preload("../utility/input_field_resource/prop_action.gd")
const PA_PropSet = preload("../utility/input_field_resource/pa_prop_set.gd")
const PA_PropEdit = preload("../utility/input_field_resource/pa_prop_edit.gd")
const PA_ArrayInsert = preload("../utility/input_field_resource/pa_array_insert.gd")
const PA_ArrayRemove = preload("../utility/input_field_resource/pa_array_remove.gd")
const PA_ArraySet = preload("../utility/input_field_resource/pa_array_set.gd")


#export
var refresh_octree_shared_LOD_variants:bool = false setget set_refresh_octree_shared_LOD_variants

# file_management
var garden_work_directory:String setget set_garden_work_directory
# gardening
var gardening_collision_mask := pow(2, 0) setget set_gardening_collision_mask

var initialized_for_edit:bool = false setget set_initialized_for_edit

var toolshed:Toolshed = null
var greenhouse:Greenhouse = null
var painter:Painter = null
var arborist:Arborist = null
var debug_viewer:DebugViewer = null

var _resource_previewer = null
var _base_control:Control = null
var _undo_redo:UndoRedo = null

var _side_panel:UI_SidePanel = null
var brush_panel:Control = null
var greenhouse_panel:Control = null

var painting_node:Spatial = null

var logger = null
var forward_input_events:bool = true


signal changed_initialized_for_edit(state)




#-------------------------------------------------------------------------------
# Lifecycle
#-------------------------------------------------------------------------------


func _init():
	set_meta("class", "Gardener")


func _ready():
	logger = Logger.get_for(self, name)
	
	# Without editor we only care about an Arborist
	# But it is already self-sufficient, so no need to initialize it
	if !Engine.editor_hint: return
	
	painting_node = Spatial.new()
	painting_node.name = "painting"
	add_child(painting_node)
	
	debug_viewer = DebugViewer.new()
	add_child(debug_viewer)
	
	init_painter()
	painter.set_brush_collision_mask(gardening_collision_mask)
	
	reload_resources()
	init_arborist()
	
	set_gardening_collision_mask(gardening_collision_mask)


func _enter_tree():
	pass


func _exit_tree():
	if !Engine.editor_hint: return
	
	apply_changes()
	stop_editing()


func _process(delta):
	if painter:
		painter.update(delta)


func apply_changes():
	if !Engine.editor_hint: return
	
	save_toolshed()
	save_greenhouse()
	toolshed.set_undo_redo(_undo_redo)
	greenhouse.set_undo_redo(_undo_redo)
#	init_arborist()


func add_child(node:Node, legible_unique_name:bool = false):
	.add_child(node, legible_unique_name)
	update_configuration_warning()




#-------------------------------------------------------------------------------
# Input
#-------------------------------------------------------------------------------


func forwarded_input(camera, event):
	if !forward_input_events: return false
	
	var handled = painter.forwarded_input(camera, event)
	if !handled:
		handled = toolshed.forwarded_input(camera, event)
	if !handled:
		handled = arborist._unhandled_input(event)
	
	return handled


# A hack to propagate editor camera
# Should be called by plugin.gd
func propagate_camera(camera:Camera):
	if arborist:
		arborist.active_camera_override = camera



#-------------------------------------------------------------------------------
# Initialization
#-------------------------------------------------------------------------------


# Initialize a Painter
# Assumed to be the first manager to initialize
func init_painter():
	painter = Painter.new(painting_node)
	painter.connect("stroke_updated", self, "on_painter_stroke_updated")
	painter.connect("changed_active_brush_size", self, "on_changed_active_brush_size")
	painter.connect("changed_active_brush_strength", self, "on_changed_active_brush_strength")
	painter.connect("stroke_started", self, "on_painter_stroke_started")
	painter.connect("stroke_finished", self, "on_painter_stroke_finished")


# Initialize the Arborist and connect it to other objects
# Won't be called without editor, as Arborist is already self-sufficient
func init_arborist():
	# A fancy way of saying
	# "Make sure there is a correct node with a correct name"
	if has_node("Arborist") && get_node("Arborist") is Arborist:
		arborist = get_node("Arborist")
		logger.info("Found existing Arborist")
	else:
		if has_node("Arborist"):
			get_node("Arborist").owner = null
			remove_child(get_node("Arborist"))
			logger.info("Removed invalid Arborist")
		arborist = Arborist.new()
		arborist.name = "Arborist"
		add_child(arborist)
		logger.info("Added new Arborist")
	
	if greenhouse:
		pair_arborist_greenhouse()
	pair_debug_viewer_arborist()
	pair_debug_viewer_greenhouse()


# Initialize a Greenhouse and a Toolshed
# Rebuild UI if needed
func reload_resources():
	var last_toolshed = toolshed
	var last_greenhouse = greenhouse
	
	toolshed = FunLib.load_res(garden_work_directory, "toolshed.tres", Defaults.DEFAULT_TOOLSHED())
	greenhouse = FunLib.load_res(garden_work_directory, "greenhouse.tres")
	if !toolshed: toolshed = Toolshed.new()
	if !greenhouse: greenhouse = Greenhouse.new()
	
	toolshed.set_undo_redo(_undo_redo)
	greenhouse.set_undo_redo(_undo_redo)
	
	if last_toolshed:
		last_toolshed.disconnect("prop_action_executed", self, "on_toolshed_prop_action_executed")
		last_toolshed.disconnect("prop_action_executed_on_brush", self, "on_toolshed_prop_action_executed_on_brush")
	FunLib.ensure_signal(toolshed, "prop_action_executed", self, "on_toolshed_prop_action_executed")
	FunLib.ensure_signal(toolshed, "prop_action_executed_on_brush", self, "on_toolshed_prop_action_executed_on_brush")
	
	if last_greenhouse:
		last_greenhouse.disconnect("prop_action_executed", self, "on_greenhouse_prop_action_executed")
		last_greenhouse.disconnect("prop_action_executed_on_plant_state", self, "on_greenhouse_prop_action_executed_on_plant_state")
		last_greenhouse.disconnect("prop_action_executed_on_plant_state_plant", self, "on_greenhouse_prop_action_executed_on_plant_state_plant")
		last_greenhouse.disconnect("prop_action_executed_on_LOD_variant", self, "on_greenhouse_prop_action_executed_on_LOD_variant")
		last_greenhouse.disconnect("req_octree_reconfigure", self, "on_greenhouse_req_octree_reconfigure")
		last_greenhouse.disconnect("req_octree_recenter", self, "on_greenhouse_req_octree_recenter")
	FunLib.ensure_signal(greenhouse, "prop_action_executed", self, "on_greenhouse_prop_action_executed")
	FunLib.ensure_signal(greenhouse, "prop_action_executed_on_plant_state", self, "on_greenhouse_prop_action_executed_on_plant_state")
	FunLib.ensure_signal(greenhouse, "prop_action_executed_on_plant_state_plant", self, "on_greenhouse_prop_action_executed_on_plant_state_plant")
	FunLib.ensure_signal(greenhouse, "prop_action_executed_on_LOD_variant", self, "on_greenhouse_prop_action_executed_on_LOD_variant")
	FunLib.ensure_signal(greenhouse, "req_octree_reconfigure", self, "on_greenhouse_req_octree_reconfigure")
	FunLib.ensure_signal(greenhouse, "req_octree_recenter", self, "on_greenhouse_req_octree_recenter")
	
	if arborist:
		pair_arborist_greenhouse()
	
	if toolshed && toolshed != last_toolshed && _side_panel:
		brush_panel = toolshed.create_ui(_base_control, _resource_previewer)
		_side_panel.set_tool_ui(brush_panel, 0)
	if greenhouse && greenhouse != last_greenhouse && _side_panel:
		greenhouse_panel = greenhouse.create_ui(_base_control, _resource_previewer)
		_side_panel.set_tool_ui(greenhouse_panel, 1)


# It's possible we load a different Greenhouse while an Arborist is already initialized
# So collapse that into a function
func pair_arborist_greenhouse():
	if !arborist || !greenhouse:
		if !arborist: logger.warn("Arborist->Greenhouse: Arborist is not initialized!")
		if !greenhouse: logger.warn("Arborist->Greenhouse: Greenhouse is not initialized!")
		return
	# We could duplicate an array, but that's additional overhead so we assume Arborist won't change it
	arborist.setup(greenhouse.greenhouse_plant_states)
	
	if !arborist.is_connected("member_count_updated", greenhouse, "plant_count_updated"):
		arborist.connect("member_count_updated", greenhouse, "plant_count_updated")


func pair_debug_viewer_greenhouse():
	if !debug_viewer || !greenhouse:
		if !debug_viewer: logger.warn("DebugViewer->Greenhouse: DebugViewer is not initialized!")
		if !greenhouse: logger.warn("DebugViewer->Greenhouse: Greenhouse is not initialized!")
		return
	
	reinit_debug_draw_brush_active()


func pair_debug_viewer_arborist():
	if !debug_viewer || !arborist:
		if !debug_viewer: logger.warn("DebugViewer->Arborist: DebugViewer is not initialized!")
		if !arborist: logger.warn("DebugViewer->Arborist: Arborist is not initialized!")
		return
	
	if !arborist.is_connected("req_debug_redraw", debug_viewer, "request_debug_redraw"):
		arborist.connect("req_debug_redraw", debug_viewer, "request_debug_redraw")




#-------------------------------------------------------------------------------
# Start/stop editing lifecycle
#-------------------------------------------------------------------------------


# Start editing (painting) a scene
func start_editing(__base_control:Control, __resource_previewer, __undoRedo:UndoRedo, __side_panel:UI_SidePanel):
	_base_control = __base_control
	_resource_previewer = __resource_previewer
	_undo_redo = __undoRedo
	
	_side_panel = __side_panel
	connect("changed_initialized_for_edit", _side_panel, "set_main_control_state")
	
	brush_panel = toolshed.create_ui(_base_control, _resource_previewer)
	greenhouse_panel = greenhouse.create_ui(_base_control, _resource_previewer)
	_side_panel.set_tool_ui(brush_panel, 0)
	_side_panel.set_tool_ui(greenhouse_panel, 1)
	toolshed.set_undo_redo(_undo_redo)
	greenhouse.set_undo_redo(_undo_redo)
	
	arborist._undo_redo = _undo_redo
	
#	# Making sure we and UI are on the same page (setting property values and checkboxes/tabs)
	painter_update_to_active_brush(toolshed.active_brush)
	_side_panel.set_main_control_state(initialized_for_edit)
	
	painter.start_editing()
	
	for i in range(0, arborist.octree_managers.size()):
		arborist.emit_member_count(i)


# Stop editing (painting) a scene
func stop_editing():
	if is_instance_valid(_side_panel):
		disconnect("changed_initialized_for_edit", _side_panel, "set_main_control_state")
		_side_panel = null
	
	if is_instance_valid(painter):
		painter.stop_editing()


# We can properly start editing only when a workDirectory is set
func validate_initialized_for_edit():
	var work_directory_valid = FunLib.is_dir_valid(garden_work_directory)
	
	# Originally there were two conditions to fulfill, not just the workDirectory
	# Keeping this in case it will be needed in the future
	var _initialized_for_edit = work_directory_valid
	if initialized_for_edit != _initialized_for_edit:
		set_initialized_for_edit(_initialized_for_edit)


# Pass a request for updating a debug view menu
func up_to_date_debug_view_menu(debug_view_menu:MenuButton):
	assert(debug_viewer)
	debug_viewer.up_to_date_debug_view_menu(debug_view_menu)
	debug_viewer.request_debug_redraw_all_active(arborist.octree_managers)


# Pass a request for checking a debug view menu flag
func debug_view_flag_checked(debug_view_menu:MenuButton, flag:int):
	assert(debug_viewer)
	debug_viewer.flag_checked(debug_view_menu, flag)
	debug_viewer.request_debug_redraw_all_active(arborist.octree_managers)




#-------------------------------------------------------------------------------
# Handle changes in owned properties
#-------------------------------------------------------------------------------


func set_gardening_collision_mask(val):
	gardening_collision_mask = val
	if painter:
		painter.set_brush_collision_mask(gardening_collision_mask)
	if arborist:
		arborist.set_gardening_collision_mask(gardening_collision_mask)


func set_garden_work_directory(val):
	if !val.ends_with("/"):
		val += "/"
	
	var changed = garden_work_directory != val
	garden_work_directory = val
	
	if !Engine.editor_hint: return
	# If we changed a directory, reload everything that resides there
	if changed:
		if is_inside_tree():
			reload_resources()
		validate_initialized_for_edit()


func set_initialized_for_edit(val):
	initialized_for_edit = val
	emit_signal("changed_initialized_for_edit", initialized_for_edit)




#-------------------------------------------------------------------------------
# Handle communication with the Greenhouse
#-------------------------------------------------------------------------------


# When Greenhouse properties are changed
func on_greenhouse_prop_action_executed(prop_action:PropAction, final_val):
	if prop_action is PA_ArrayInsert:
		arborist.on_plant_added(final_val[prop_action.index], prop_action.index)
		reinit_debug_draw_brush_active()
	elif prop_action is PA_ArrayRemove:
		arborist.on_plant_removed(prop_action.val, prop_action.index)
		reinit_debug_draw_brush_active()


# When Greenhouse_PlantState properties are changed
func on_greenhouse_prop_action_executed_on_plant_state(prop_action:PropAction, final_val, plant_state):
	var plant_index = greenhouse.greenhouse_plant_states.find(plant_state)
	
	match prop_action.prop:
		"plant/plant_brush_active":
			if prop_action is PA_PropSet || prop_action is PA_PropEdit:
				debug_viewer.set_brush_active_plant(plant_state.plant_brush_active, plant_index)
				debug_viewer.request_debug_redraw_all_active(arborist.octree_managers)


# When Greenhouse_Plant properties are changed
func on_greenhouse_prop_action_executed_on_plant_state_plant(prop_action:PropAction, final_val, plant, plant_state):
	var plant_index = greenhouse.greenhouse_plant_states.find(plant_state)
	
	match prop_action.prop:
		"mesh/mesh_LOD_variants":
			if prop_action is PA_ArrayInsert:
				var mesh_index = prop_action.index
				arborist.on_LOD_variant_added(plant_index, mesh_index, final_val[mesh_index])
			elif prop_action is PA_ArrayRemove:
				var mesh_index = prop_action.index
				arborist.on_LOD_variant_removed(plant_index, mesh_index)
			elif prop_action is PA_ArraySet:
				var mesh_index = prop_action.index
				arborist.on_LOD_variant_set(plant_index, mesh_index, final_val[mesh_index])
		
		"mesh/mesh_LOD_max_distance":
			if prop_action is PA_PropSet || prop_action is PA_PropEdit:
				arborist.update_plant_LOD_max_distance(plant_index, final_val)
		
		"mesh/mesh_LOD_kill_distance":
			if prop_action is PA_PropSet || prop_action is PA_PropEdit:
				arborist.update_plant_LOD_kill_distance(plant_index, final_val)


# When Greenhouse_LODVariant properties are changed
func on_greenhouse_prop_action_executed_on_LOD_variant(prop_action:PropAction, final_val, LOD_variant, plant, plant_state):
	var plant_index = greenhouse.greenhouse_plant_states.find(plant_state)
	var mesh_index = plant.mesh_LOD_variants.find(LOD_variant)
	
	match prop_action.prop:
		"spawned_spatial":
			if prop_action is PA_PropSet || prop_action is PA_PropEdit:
				arborist.on_LOD_variant_prop_changed_spawned_spatial(plant_index, mesh_index, final_val)
		"shadow_casting_mode":
			if prop_action is PA_PropSet || prop_action is PA_PropEdit:
				arborist.recenter_octree(plant_state, plant_index) #to force a refresh


# A request to reconfigure an octree
func on_greenhouse_req_octree_reconfigure(plant, plant_state):
	var plant_index = greenhouse.greenhouse_plant_states.find(plant_state)
	arborist.reconfigure_octree(plant_state, plant_index)


# A request to recenter an octree
func on_greenhouse_req_octree_recenter(plant, plant_state):
	var plant_index = greenhouse.greenhouse_plant_states.find(plant_state)
	arborist.recenter_octree(plant_state, plant_index)


# Update brush active indexes for DebugViewer
func reinit_debug_draw_brush_active():
	debug_viewer.reset_brush_active_plants()
	for plant_index in range(0, greenhouse.greenhouse_plant_states.size()):
		var plant_state = greenhouse.greenhouse_plant_states[plant_index]
		debug_viewer.set_brush_active_plant(plant_state.plant_brush_active, plant_index)
	debug_viewer.request_debug_redraw_all_active(arborist.octree_managers)




#-------------------------------------------------------------------------------
# Painter stroke lifecycle
#-------------------------------------------------------------------------------


func on_painter_stroke_started(brush_data:Dictionary):
	var active_brush = toolshed.active_brush
	arborist.on_stroke_started(active_brush, greenhouse.greenhouse_plant_states)


func on_painter_stroke_finished(brush_data:Dictionary):
	arborist.on_stroke_finished()


func on_painter_stroke_updated(brush_data:Dictionary):
	arborist.on_stroke_updated(brush_data)




#-------------------------------------------------------------------------------
# Painter - Toolshed relations
#-------------------------------------------------------------------------------


# Changed active brush from Toolshed. Update the painter
func on_toolshed_prop_action_executed(prop_action:PropAction, final_val):
	assert(painter)
	if !(prop_action is PA_PropSet) && !(prop_action is PA_PropEdit): return
	if final_val != toolshed.active_brush:
		logger.error("Passed final_val is not equal to toolshed.active_brush!")
		return
	
	painter_update_to_active_brush(final_val)


func painter_update_to_active_brush(active_brush):
	assert(active_brush)
	var max_size = FunLib.get_setting_safe("dreadpons_spatial_gardener/input_and_ui/brush_size_slider_max_value", 100.0)
	var max_strength = 1.0
	
	painter.set_active_brush_max_size(max_size)
	painter.set_active_brush_max_strength(max_strength)
	painter.set_active_brush_size(active_brush.shape_size)
	painter.set_active_brush_strength(active_brush.behavior_strength)



#-------------------------------------------------------------------------------
# Quick edit for brush properties
#-------------------------------------------------------------------------------


# Property change instigated by painter
func on_changed_active_brush_size(val, final:bool):
	var prop_action
	if final:
		prop_action = PA_PropSet.new("shape/shape_size", val)
	else:
		prop_action = PA_PropEdit.new("shape/shape_size", val)
	
	toolshed.active_brush.request_prop_action(prop_action)


# Property change instigated by painter
func on_changed_active_brush_strength(val, final:bool):
	var prop_action
	if final:
		prop_action = PA_PropSet.new("behavior/behavior_strength", val)
	else:
		prop_action = PA_PropEdit.new("behavior/behavior_strength", val)
	
	toolshed.active_brush.request_prop_action(prop_action)


# Propagate active_brush property changes to Painter
func on_toolshed_prop_action_executed_on_brush(prop_action:PropAction, final_val, brush):
	assert(painter)
	if !(prop_action is PA_PropSet) && !(prop_action is PA_PropEdit): return
	if brush != toolshed.active_brush: return
	
	if prop_action.prop == "shape/shape_size":
		painter.set_active_brush_size(final_val)
	elif prop_action.prop == "behavior/behavior_strength":
		painter.set_active_brush_strength(final_val)




#-------------------------------------------------------------------------------
# Saving, loading and file management
#-------------------------------------------------------------------------------


func save_toolshed():
	FunLib.save_res(toolshed, garden_work_directory, "toolshed.tres")


func save_greenhouse():
	FunLib.save_res(greenhouse, garden_work_directory, "greenhouse.tres")







#-------------------------------------------------------------------------------
# Property export
#-------------------------------------------------------------------------------


# Writing this by hand THRICE for each property is honestly tiring
# Built-in Godot reflection would go a long way
func _get(property):
	if property == "file_management/garden_work_directory":
		return garden_work_directory
	elif property == "gardening/gardening_collision_mask":
		return gardening_collision_mask


func _set(property, val):
	var return_val = true
	
	match property:
		"file_management/garden_work_directory":
			set_garden_work_directory(val)
		"gardening/gardening_collision_mask":
			set_gardening_collision_mask(val)
		_:
			return_val = false
	
	return return_val


func _get_property_list():
	return [
		{
			"name": "file_management/garden_work_directory",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
			"hint": PROPERTY_HINT_DIR
		},
		{
			"name": "gardening/gardening_collision_mask",
			"type": TYPE_INT,
			"usage": PROPERTY_USAGE_DEFAULT,
			"hint": PROPERTY_HINT_LAYERS_3D_PHYSICS
		},
	]


# Warning to be displayed in editor SceneTree
func _get_configuration_warning():
	var arborist_check = get_node("Arborist")
	if arborist_check && arborist_check is Arborist:
		return ""
	else:
		return "Gardener is missing a valid Arborist child\nSince it should be created automatically, try reloading a scene or recreating a Gardener"


func set_refresh_octree_shared_LOD_variants(val):
	refresh_octree_shared_LOD_variants = false
	if val && arborist && greenhouse:
		for i in range(0, greenhouse.greenhouse_plant_states.size()):
			arborist.refresh_octree_shared_LOD_variants(i, greenhouse.greenhouse_plant_states[i].plant.mesh_LOD_variants)

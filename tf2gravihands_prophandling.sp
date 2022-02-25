#if defined _tf2gravihands_prophandling
 #endinput
#endif
#define _tf2gravihands_prophandling

#if !defined _tf2gravihands
 #error Please compile the main file!
#endif

#define DUMMY_MODEL "models/class_menu/random_class_icon.mdl"
#define GRAB_DISTANCE 150.0

#define GH_SOUND_PICKUP "weapons/physcannon/physcannon_pickup.wav"
#define GH_SOUND_DROP "weapons/physcannon/physcannon_drop.wav"
#define GH_SOUND_TOOHEAVY "weapons/physcannon/physcannon_tooheavy.wav"
#define GH_SOUND_INVALID "weapons/physcannon/physcannon_dryfire.wav"
#define GH_SOUND_THROW "weapons/physcannon/superphys_launch1.wav"
#define GH_ACTION_PICKUP 1
#define GH_ACTION_DROP 2
#define GH_ACTION_TOOHEAVY 3
#define GH_ACTION_INVALID 4
#define GH_ACTION_THROW 5

enum struct GraviPropData {
	int rotProxyEnt;
	int grabbedEnt;
	float previousEnd[3]; //allows flinging props
	float lastValid[3]; //prevent props from being dragged through walls
	bool dontCheckStartPost; //aabbs collide easily, allow pulling props out of those situations
	Collision_Group_t collisionFlags;// collisionFlags of held prop
	bool forceDropProp;
	bool blockPunt; //from spawnflags
	float grabDistance;
	float playNextAction;
	int lastAudibleAction;
	float nextPickup;
	int lastInteractedEnt;
	float lastInteractedTime;
	
	void Reset() {
		this.rotProxyEnt = INVALID_ENT_REFERENCE;
		this.grabbedEnt = INVALID_ENT_REFERENCE;
		ScaleVector(this.previousEnd, 0.0);
		ScaleVector(this.lastValid, 0.0);
		this.dontCheckStartPost = false;
		this.forceDropProp = false;
		this.grabDistance = -1.0;
		this.playNextAction = 0.0;
		this.lastAudibleAction = 0;
		this.nextPickup = 0.0;
	}
}
GraviPropData GravHand[MAXPLAYERS+1];

// if we parent the entity to a dummy, we don't have to care about the offset matrix
static int getOrCreateProxyEnt(int client, float atPos[3]) {
	int ent = EntRefToEntIndex(GravHand[client].rotProxyEnt);
	if (ent == INVALID_ENT_REFERENCE) {
		ent = CreateEntityByName("prop_dynamic_override");//CreateEntityByName("info_target");
		DispatchKeyValue(ent, "model", DUMMY_MODEL);
		SetEntPropFloat(ent, Prop_Send, "m_flModelScale", 0.0);
		DispatchSpawn(ent);
		TeleportEntity(ent, atPos, NULL_VECTOR, NULL_VECTOR);
		GravHand[client].rotProxyEnt = EntIndexToEntRef(ent);
	}
	return ent;
}

public bool grabFilter(int entity, int contentsMask, int client) {
	return entity != client
		&& entity > MaxClients //never clients
		&& IsValidEntity(entity) //don't grab stale refs
		&& entity != EntRefToEntIndex(GravHand[client].rotProxyEnt) //don't grab rot proxies
		&& entity != EntRefToEntIndex(GravHand[client].grabbedEnt) //don't grab grabbed stuff
		&& GetEntPropEnt(entity, Prop_Send, "moveparent")==INVALID_ENT_REFERENCE; //never grab stuff that's parented (already)
}

//static char[] vecfmt(float vec[3]) {
//	char buf[32];
//	Format(buf, sizeof(buf), "(%.2f, %.2f, %.2f)", vec[0], vec[1], vec[2]);
//	return buf;
//}

static void computeBounds(int entity, float mins[3], float maxs[3]) {
	float v[3]={8.0,...}; //helper, defining size of bounds box
	//entities stay inbounds if their COM is inside (thanks vphysics on this one)
	Entity_GetMinSize(entity, mins);
	Entity_GetMaxSize(entity, maxs);
	AddVectors(mins,maxs,mins);
	ScaleVector(mins,0.5); //mins = now COM
	
	//create equidistant box to keep origin of prop in world
	AddVectors(mins,v,maxs);
	SubtractVectors(mins,v,mins);
}

/** 
 * @param targetPoint as ray end or max distance in look direction
 * @return entity under cursor if any
 */
static int pew(int client, float targetPoint[3], float scanDistance) {
	float eyePos[3], eyeAngles[3], fwrd[3];
	GetClientEyePosition(client, eyePos);
	GetClientEyeAngles(client, eyeAngles);
//	GetAngleVectors(eyeAngles, fwrd, NULL_VECTOR, NULL_VECTOR);
	Handle trace = TR_TraceRayFilterEx(eyePos, eyeAngles, MASK_SOLID, RayType_Infinite, grabFilter, client);
	int cursor = INVALID_ENT_REFERENCE;
	if(TR_DidHit(trace)) {
		float vecTarget[3];
		TR_GetEndPosition(vecTarget, trace);
		
		float maxdistance = (EntRefToEntIndex(GravHand[client].grabbedEnt)==INVALID_ENT_REFERENCE) ? scanDistance : GravHand[client].grabDistance;
		float distance = GetVectorDistance(eyePos, vecTarget);
		if(distance > maxdistance) { //looking beyond the held entity
			GetAngleVectors(eyeAngles, fwrd, NULL_VECTOR, NULL_VECTOR);
			ScaleVector(fwrd, maxdistance);
			AddVectors(eyePos, fwrd, targetPoint);
		} else { //maybe looking at a wall
			targetPoint = vecTarget;
		}
		
		int entity = TR_GetEntityIndex(trace);
		if (entity>0 && distance <= scanDistance) {
			cursor = entity;
		}
	}
	CloseHandle(trace);
	return cursor;
}

//public bool seeCenterFilter(int entity, int contentsMask, int prop) {
//	return !entity || (entity > MaxClients && entity != prop);
//}
//
//static bool checkPropCenterVisible(int client, int prop) {
//	//require los to COM to be unobstructed
//	float vec1[3], vec2[3];
//	Entity_GetMinSize(prop, vec1);
//	Entity_GetMaxSize(prop, vec2);
//	AddVectors(vec1, vec2, vec1);
//	ScaleVector(vec1, 0.5);
//	GetClientEyePosition(client, vec2);
//	TR_TraceRayFilter(vec1, vec2, MASK_SOLID, RayType_EndPoint, seeCenterFilter, prop);
//	return !TR_DidHit();
//}

static bool movementCollides(int client, float endpos[3], bool onlyTarget) {
	//check if prop would collide at target position
	float offset[3], from[3], to[3], mins[3], maxs[3];
	int grabbed = EntRefToEntIndex(GravHand[client].grabbedEnt);
	if (grabbed == INVALID_ENT_REFERENCE) ThrowError("%L is not currently grabbing anything", client);
	//get movement
	SubtractVectors(endpos, GravHand[client].lastValid, offset);
	Entity_GetAbsOrigin(grabbed, from);
	AddVectors(from, offset, to);
	if (onlyTarget) {
		from[0]=to[0]-0.1;
		from[1]=to[1]-0.1;
		from[2]=to[2]-0.1;
	}
	computeBounds(grabbed, mins, maxs);
	//trace it
	Handle trace = TR_TraceHullFilterEx(from, to, mins, maxs, MASK_SOLID, grabFilter, client);
	bool result = TR_DidHit(trace);
	delete trace;
	return result;
}

bool clientCmdHoldProp(int client, int &buttons, float velocity[3], float angles[3]) {
//	float yawAngle[3];
//	yawAngle[1] = angles[1];
	int activeWeapon = Client_GetActiveWeapon(client);
	int defIndex = (activeWeapon == INVALID_ENT_REFERENCE) ? INVALID_ITEM_DEFINITION : GetEntProp(activeWeapon, Prop_Send, "m_iItemDefinitionIndex");
	if (defIndex == 5) {
		if ((buttons & IN_ATTACK2) && !GravHand[client].forceDropProp) {
			if (GetEntPropFloat(client, Prop_Send, "m_flNextAttack") - GetGameTime() < 0.1) {
				SetEntPropFloat(client, Prop_Send, "m_flNextAttack", GetGameTime() + 0.5);
			}
			float clientTime = GetClientTime(client);
			if (GravHand[client].nextPickup - clientTime > 0) return false;
			
			int grabbed = EntRefToEntIndex(GravHand[client].grabbedEnt);
			//grabbing
			if (grabbed == INVALID_ENT_REFERENCE) { //try to pick up cursorEnt
				if (!(gGraviHandsGrabDistance>0.0 && TryPickupCursorEnt(client, angles)) &&
					!(gGraviHandsPullDistance>0.0 && TryPullCursorEnt(client, angles)) ) {
					//if another sound already played, nothing will happen
					PlayActionSound(client, GH_ACTION_INVALID);
					return false;
				}
			} else {
				ThinkHeldProp(client, grabbed, buttons, angles);
			}
			return true;
		} else if (!(buttons & IN_ATTACK2)) {
			SetEntPropFloat(client, Prop_Send, "m_flFirstPrimaryAttack", 0.0);
			SetEntPropFloat(client, Prop_Send, "m_flNextAttack", 0.0);
			buttons &=~ IN_ATTACK2;
		}
	}
	//drop anything held
	return ForceDropItem(client, buttons & IN_ATTACK && GravHand[client].forceDropProp, velocity, angles);
}

#define PickupFlag_MotionDisabled 0x01
#define PickupFlag_SpawnFlags 0x02
#define PickupFlag_TooHeavy 0x04
#define PickupFlag_BlockPunting 0x100
#define PickupFlag_EnableMotion 0x200
static bool TryPickupCursorEnt(int client, float yawAngle[3]) {
	float endpos[3], killVelocity[3];
	int cursorEnt = pew(client, endpos, gGraviHandsGrabDistance);
	if (cursorEnt == INVALID_ENT_REFERENCE) {
		return false;
	}
	int rotProxy = getOrCreateProxyEnt(client, endpos);
	
	//check if cursor is a entity we can grab
	char classname[20];
	GetEntityClassname(cursorEnt, classname, sizeof(classname));
	int pickupFlags = 0;
	if (StrContains(classname, "prop_physics")==0) {
		if (Entity_GetFlags(cursorEnt) & FL_FROZEN) {
			pickupFlags |= PickupFlag_MotionDisabled;
		} else {
			int spawnFlags = Entity_GetSpawnFlags(cursorEnt);
			bool motion = Phys_IsMotionEnabled(cursorEnt);
			if ((spawnFlags & SF_PHYSPROP_ENABLE_ON_PHYSCANNON) && !motion) {
				pickupFlags |= PickupFlag_EnableMotion;
				motion = true;
			}
			if (!(spawnFlags & SF_PHYSPROP_ALWAYS_PICK_UP)) {
				if (spawnFlags & SF_PHYSPROP_PREVENT_PICKUP)
					pickupFlags |= PickupFlag_SpawnFlags;
				if (GetEntityMoveType(cursorEnt)==MOVETYPE_NONE || !motion)
					pickupFlags |= PickupFlag_MotionDisabled;
				if (Phys_GetMass(cursorEnt)>gGraviHandsMaxWeight)
					pickupFlags |= PickupFlag_TooHeavy;
			}
		}
	} else if (StrEqual(classname, "func_physbox")) {
		if (Entity_GetFlags(cursorEnt) & FL_FROZEN) {
			pickupFlags |= PickupFlag_MotionDisabled;
		} else {
			int spawnFlags = Entity_GetSpawnFlags(cursorEnt);
			bool motion = Phys_IsMotionEnabled(cursorEnt);
			if ((spawnFlags & SF_PHYSBOX_ENABLE_ON_PHYSCANNON) && !motion) {
				pickupFlags |= PickupFlag_EnableMotion;
				motion = true;
			}
			if (!(spawnFlags & SF_PHYSBOX_ALWAYS_PICK_UP)) {
				if (spawnFlags & SF_PHYSBOX_NEVER_PICK_UP)
					pickupFlags |= PickupFlag_SpawnFlags;
				if (GetEntityMoveType(cursorEnt)==MOVETYPE_NONE || !motion)
					pickupFlags |= PickupFlag_MotionDisabled;
				if (Phys_GetMass(cursorEnt)>gGraviHandsMaxWeight)
					pickupFlags |= PickupFlag_TooHeavy;
			}
			if ((spawnFlags & SF_PHYSBOX_NEVER_PUNT)!=0) pickupFlags |= PickupFlag_BlockPunting;
		}
	} else if (StrEqual(classname, "tf_dropped_weapon") || StrEqual(classname, "tf_ammo_pack")) {
		pickupFlags = 0;
	} else { //not an entity we could pick up
		PlayActionSound(client,GH_ACTION_INVALID);
		return false;
	}
	//ok we now have a potential candidate for grabbing and collected some meta info
	// lets ask all other plugins if they are ok with us grabbing this thing
	if (!NotifyGraviHandsGrab(client, cursorEnt, pickupFlags)) { //plugins said no
		PlayActionSound(client,GH_ACTION_INVALID);
		return false;
	}
	if ((pickupFlags & 0xff)) { //if not plugin blocked but still not possible, i want to react to the tooheavy flag
		PlayActionSound(client, (pickupFlags == PickupFlag_TooHeavy)?GH_ACTION_TOOHEAVY:GH_ACTION_INVALID);
		return false;
	}
	//ok now we can finally pick this thing up
	if ((pickupFlags & PickupFlag_EnableMotion)!=0 && !Phys_IsMotionEnabled(cursorEnt)) {
		//Phys_EnableMotion(cursorEnt, true);
		AcceptEntityInput(cursorEnt, "EnableMotion", client, client);
	}
	GravHand[client].blockPunt = ((pickupFlags & PickupFlag_BlockPunting)!=0);
	
	//generate outputs
	FireEntityOutput(cursorEnt, "OnPhysGunPickup", client);
	//check if this entity is already grabbed
	for (int i=1;i<=MaxClients;i++) {
		if (cursorEnt == EntRefToEntIndex(GravHand[client].grabbedEnt)) {
			PlayActionSound(client,GH_ACTION_INVALID);
			return false;
		}
	}
	//position entities
	TeleportEntity(rotProxy, endpos, yawAngle, NULL_VECTOR);
	TeleportEntity(cursorEnt, NULL_VECTOR, NULL_VECTOR, killVelocity);
	//grab entity
	GravHand[client].grabbedEnt = EntIndexToEntRef(cursorEnt);
	float vec[3];
	GetClientEyePosition(client, vec);
	GravHand[client].grabDistance = Entity_GetDistanceOrigin(rotProxy, vec);
	//parent to make rotating easier
	SetVariantString("!activator");
	AcceptEntityInput(cursorEnt, "SetParent", rotProxy);
	//other setup
	GravHand[client].lastValid = endpos;
	GravHand[client].previousEnd = endpos;
	GravHand[client].dontCheckStartPost = movementCollides(client, endpos, true);
	GravHand[client].collisionFlags = Entity_GetCollisionGroup(cursorEnt);
	Entity_SetCollisionGroup(cursorEnt, COLLISION_GROUP_DEBRIS_TRIGGER);
	GravHand[client].lastInteractedEnt = GravHand[client].grabbedEnt;
	GravHand[client].lastInteractedTime = GetGameTime();
	//sound
	PlayActionSound(client,GH_ACTION_PICKUP);
	//notify plugins
	NotifyGraviHandsGrabPost(client, cursorEnt);
	return true;
}

static bool TryPullCursorEnt(int client, float yawAngle[3]) {
	float target[3], eyePos[3];
	float force[3], grav[3];
	char classname[64];
	
	int entity = pew(client, target, gGraviHandsPullDistance);
	if (entity == INVALID_ENT_REFERENCE) return false;
	Entity_GetClassName(entity, classname, sizeof(classname));
	if (StrContains(classname,"prop_physics")!=0 && !StrEqual(classname, "func_physbox")
		&& !StrEqual(classname, "tf_dropped_weapon") && !StrEqual(classname, "tf_ammo_pack")) return false;
	
	GetAngleVectors(yawAngle, force, NULL_VECTOR, NULL_VECTOR);
	GetClientEyePosition(client, eyePos);
	//manipulate the target position to be grab distance in front of the player
	float dist = gGraviHandsGrabDistance < 50.0 ? 50.0 : gGraviHandsGrabDistance;
	grav = force; //abuse the grav vector for distance
	ScaleVector(grav, dist);
	AddVectors(eyePos, grav, eyePos);
	//lerp the force over the distance
	dist = GetVectorDistance(eyePos, target);
	float normalizedDistance = 1.0-(dist / gGraviHandsPullDistance); //1- because we want to pull towards the player
	float forceRange = gGraviHandsPullForceNear-gGraviHandsPullForceFar; //force range
	float forceScale = normalizedDistance * forceRange + gGraviHandsPullForceFar; //scaled over range + min
	ScaleVector(force, -forceScale);
	Phys_GetEnvironmentGravity(grav);
	SubtractVectors(force, grav, force);
	Phys_ApplyForceCenter(entity, force);
//	Phys_ApplyForceOffset(entity, force, target); //does weird stuff :o
	
	//play sound
	if (EntRefToEntIndex(GravHand[client].lastInteractedEnt) != entity) {
		GravHand[client].lastInteractedEnt = EntIndexToEntRef(entity);
		PlayActionSound(client, GH_ACTION_TOOHEAVY); //i think that was the same sound?
	}
	GravHand[client].lastInteractedTime = GetGameTime();
	return true;
}

static void ThinkHeldProp(int client, int grabbed, int buttons, float yawAngle[3]) {
	float endpos[3], killVelocity[3];
	pew(client, endpos, gGraviHandsGrabDistance);
	int rotProxy = getOrCreateProxyEnt(client, endpos);
	if (rotProxy != INVALID_ENT_REFERENCE && grabbed != INVALID_ENT_REFERENCE) { //holding
		if (!movementCollides(client, endpos, GravHand[client].dontCheckStartPost)) {
			if (buttons & IN_ATTACK && !GravHand[client].blockPunt) { //punt
				GravHand[client].forceDropProp = true;
			} else {
				GravHand[client].lastValid = endpos;
				GravHand[client].previousEnd = endpos;
				GravHand[client].dontCheckStartPost = false;
				TeleportEntity(rotProxy, endpos, yawAngle, killVelocity);
			}
		} else if (GetVectorDistance(GravHand[client].lastValid, endpos) > gGraviHandsDropDistance) {
			GravHand[client].forceDropProp = true;
		}
		GravHand[client].lastInteractedEnt = EntIndexToEntRef(grabbed);
		GravHand[client].lastInteractedTime = GetGameTime();
	}
}

bool ForceDropItem(int client, bool punt=false, const float dvelocity[3]=NULL_VECTOR, const float dvangles[3]=NULL_VECTOR) {
	bool didStuff = false;
	int entity;
	if ((entity = EntRefToEntIndex(GravHand[client].grabbedEnt))!=INVALID_ENT_REFERENCE) {
		float vec[3], origin[3];
		Entity_GetAbsOrigin(entity, origin);
		AcceptEntityInput(entity, "ClearParent");
		//fling
		bool didPunt;
		pew(client, vec, gGraviHandsDropDistance);
		if (punt && !IsNullVector(dvangles)) { //punt
			GetAngleVectors(dvangles, vec, NULL_VECTOR, NULL_VECTOR);
			ScaleVector(vec, gGraviHandsPuntForce * 100.0 / Phys_GetMass(entity));
//				AddVectors(vec, fwd, vec);
//			PrintToServer("Punting Prop with Mass %f", Phys_GetMass(entity));
			didPunt=true;
		} else if (!movementCollides(client, vec, false)) { //throw with swing
			SubtractVectors(vec, GravHand[client].previousEnd, vec);
			ScaleVector(vec, 25.0); //give oomph
		} else {
			ScaleVector(vec, 0.0); //set 0
		}
		if (!IsNullVector(dvelocity)) AddVectors(vec, dvelocity, vec);
		float zeros[3];
		TeleportEntity(entity, origin, NULL_VECTOR, zeros); //rest entity
		Phys_AddVelocity(entity, vec, zeros);//use vphysics to accelerate, is more stable
		
		//fire output that the ent was dropped
		FireEntityOutput(entity, punt?"OnPhysGunPunt":"OnPhysGunDrop", client);
		//reset ref because we're nice
		Entity_SetCollisionGroup(entity, GravHand[client].collisionFlags);
		GravHand[client].grabbedEnt = INVALID_ENT_REFERENCE;
		NotifyGraviHandsDropped(client, entity, didPunt);
		GravHand[client].nextPickup = GetClientTime(client) + (punt?0.5:0.1);
		//play sound
		PlayActionSound(client,didPunt?GH_ACTION_THROW:GH_ACTION_DROP);
		didStuff = true;
	}
	if ((entity = EntRefToEntIndex(GravHand[client].rotProxyEnt))!=INVALID_ENT_REFERENCE) {
		RequestFrame(killEntity, entity);
		GravHand[client].rotProxyEnt = INVALID_ENT_REFERENCE;
		didStuff = true;
	}
	GravHand[client].collisionFlags = COLLISION_GROUP_NONE;
	GravHand[client].grabDistance=0.0;
	GravHand[client].forceDropProp=false;
	return didStuff;
}

void PlayActionSound(int client, int sound) {
	float ct = GetClientTime(client);
	if (GravHand[client].lastAudibleAction != sound || GravHand[client].playNextAction - ct < 0) {
		switch (sound) {
			case GH_ACTION_PICKUP: {
				EmitSoundToAll(GH_SOUND_PICKUP, client);
				GravHand[client].playNextAction = ct + 1.5;
			}
			case GH_ACTION_DROP: {
				EmitSoundToAll(GH_SOUND_DROP, client);
				GravHand[client].playNextAction = ct + 1.5;
			}
			case GH_ACTION_TOOHEAVY: {
				EmitSoundToAll(GH_SOUND_TOOHEAVY, client);
				GravHand[client].playNextAction = ct + 1.5;
			}
			case GH_ACTION_INVALID: {
				EmitSoundToAll(GH_SOUND_INVALID, client);
				GravHand[client].playNextAction = ct + 0.5;
			}
			case GH_ACTION_THROW: {
				EmitSoundToAll(GH_SOUND_THROW, client);
				GravHand[client].playNextAction = ct + 0.5;
			}
			default: {
				GravHand[client].playNextAction = ct + 1.5;
			}
		}
		GravHand[client].lastAudibleAction = sound;
	}
}

static void killEntity(int entity) {
	if (IsValidEntity(entity))
		AcceptEntityInput(entity, "Kill");
}

bool FixPhysPropAttacker(int victim, int& attacker, int& inflictor, int& damagetype) {
	if (attacker == inflictor && victim != attacker && !IsValidClient(attacker)) {
		char classname[64];
		Entity_GetClassName(attacker, classname, sizeof(classname));
		if (StrEqual(classname, "func_physbox") || StrContains(classname, "prop_physics")==0) {
			//victim is damaged by physics object, search thrower in our data
			float time;
			int thrower=-1;
			for (int c=1;c<=MaxClients;c++) {
				if (IsValidClient(c) && EntRefToEntIndex(GravHand[c].lastInteractedEnt) == attacker && GravHand[c].lastInteractedTime > time) {
					thrower = c;
					time = GravHand[c].lastInteractedTime;
				}
			}
			if (thrower > 0 && GetGameTime()-time < 7.0) { //we got a thrower, but timeout interactions
				//rewrite attacker
				attacker = thrower;
				//no self damage (a but too easy to do)
				bool blockDamage = attacker == victim;
				//I know that this is not the inteded use, but TF2 has no other use either
				damagetype |= DMG_PHYSGUN;
				//pvp plugin integration
				if (depOptInPvP && !pvp_CanAttack(attacker, victim)) {
					blockDamage = true;
				}
				
				return blockDamage;
			}
		}
	}
	return false;
}

//stock void DebugLine(int client, const float from[3], const float to[3]) {
//	int color[]={255,255,255,255};
//	TE_SetupBeamPoints(from, to, PrecacheModel("materials/sprites/laserbeam.vmt", false), 0, 0, 1, 1.0, 1.0, 1.0, 0, 0.0, color, 0);
//	TE_SendToClient(client);
//}

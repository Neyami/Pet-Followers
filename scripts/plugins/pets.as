// Based on GHW Pet Followers by GHW_Chronic
#include "../ChatCommandManager" //By the svencoop team, should come with the game (svencoop\scripts\)

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "Nero" );
	g_Module.ScriptInfo.SetContactInfo( "https://discord.gg/0wtJ6aAd7XOGI6vI" );
	g_Module.ScriptInfo.SetMinimumAdminLevel( ADMIN_YES ); //remove this line if it prevents non-admins from using the chatcommands (it shouldn't :hehe:)

	g_Hooks.RegisterHook( Hooks::Player::PlayerSpawn, @Pets::PlayerSpawn );
	g_Hooks.RegisterHook( Hooks::Player::PlayerKilled, @Pets::PlayerKilled );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @Pets::ClientDisconnect );
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @Pets::ClientSay );

	@Pets::g_cvarHideChat = CCVar( "pets_hidechat", 0, "0/1 Suppress player chat when using plugin.", ConCommandFlag::AdminOnly );
	@Pets::g_cvarHideInfo = CCVar( "pets_hideinfo", 0, "0/1 Suppress info chat from plugin.", ConCommandFlag::AdminOnly );

	@Pets::g_ChatCommands = ChatCommandSystem::ChatCommandManager();

	Pets::g_ChatCommands.AddCommand( ChatCommandSystem::ChatCommand("pet", @Pets::pet_cmd_handle, false, 1, "(petname/menu/off) <scale, up to 0.9> - summon pet, show menu, or remove pet.") );

	if( Pets::g_petThink !is null )
		g_Scheduler.RemoveTimer( Pets::g_petThink );

	@Pets::g_petThink = g_Scheduler.SetInterval( "PetThink", Pets::m_flThinkRate );
}

void MapInit()
{
	Pets::g_petModels.deleteAll();
	Pets::ReadPets();
	array<string> petNames = Pets::g_petModels.getKeys();

	for( uint i = 0; i < petNames.length(); ++i )
	{
		Pets::PetData@ pData = cast<Pets::PetData@>(Pets::g_petModels[petNames[i]]);
		g_Game.PrecacheModel( "models/" + pData.sModelPath + ".mdl" );
	}

	Pets::g_petUsers.deleteAll();
	Pets::g_petUserPets.deleteAll();

	if( @Pets::petMenu !is null )
	{
		Pets::petMenu.Unregister();
		@Pets::petMenu = null;
	}

	array<string> petUsers = Pets::g_petCrossover.getKeys();

	for( uint i = 0; i < petUsers.length(); ++i )
	{
		Pets::PetCrossover@ cData = cast<Pets::PetCrossover@>(Pets::g_petCrossover[petUsers[i]]);
		cData.iCount = cData.iCount + 1;
		cData.bCounted = false;
		Pets::g_petCrossover[petUsers[i]] = cData;

		if( cData.iCount >= 3 )
			Pets::g_petCrossover.delete(petUsers[i]);
	}

	if( Pets::g_petThink !is null )
		g_Scheduler.RemoveTimer( Pets::g_petThink );

	@Pets::g_petThink = g_Scheduler.SetInterval( "PetThink", Pets::m_flThinkRate );
}

namespace Pets
{
	//DON'T USE THIS WHEN ADDING OR REMOVING PETS, ONLY FOR EDITING EXISTING ENTRIES IN pets.txt
	//Restart the map when adding or removing pets
	CClientCommand pets_reload( "pets_reload", "Reloads pet-definitions from pets.txt.", @ReloadPetsCMD );
	ChatCommandSystem::ChatCommandManager@ g_ChatCommands = null;

	dictionary g_petUsers;
	dictionary g_petUserPets;
	dictionary g_petModels;
	string g_petsFile = "scripts/plugins/pets.txt";
	CTextMenu@ petMenu = null;
	dictionary g_petCrossover;
	CCVar@ g_cvarHideChat;
	CCVar@ g_cvarHideInfo;
	const float m_flThinkRate = 0.1;
	CScheduledFunction@ g_petThink = null;
	array<float> flTimeToDie(33);
	array<bool> bRemovePet(33);

	class PetData
	{
		string sName;
		string sModelPath;
		float flScale;
		int iIdleAnim;
		float flIdleSpeed;
		int iRunAnim;
		float flRunSpeed;
		int iDeathAnim;
		float flDeathLength;
		float flMinusZStanding;
		float flMinusZCrouching;
		float flMaxDistance;
		float flMinDistance;
		string sBoneControllers;
		//bool bDynamic; //todo
	}

	class PetCrossover
	{
		string sPet;
		float flScale;
		int iCount;
		bool bCounted;
	}

	HookReturnCode PlayerSpawn( CBasePlayer@ pPlayer )
	{
		string sSteamID = g_EngineFuncs.GetPlayerAuthId( pPlayer.edict() );
		int id = pPlayer.entindex();
		flTimeToDie[id] = 0;
		bRemovePet[id] = false;

		if( g_petCrossover.exists(sSteamID) )
			g_Scheduler.SetTimeout( "playerPostSpawn", 1.5, id, sSteamID );

		return HOOK_CONTINUE;
	}

	HookReturnCode PlayerKilled( CBasePlayer@ pPlayer, CBaseEntity@ pAttacker, int iGib )
	{
		handle_death( pPlayer, false );

		return HOOK_CONTINUE;
	}

	HookReturnCode ClientDisconnect( CBasePlayer@ pPlayer )
	{
		removepet( pPlayer, true );

		return HOOK_CONTINUE;
	}

	HookReturnCode ClientSay( SayParameters@ pParams )
	{		
		if( g_ChatCommands.ExecuteCommand(pParams) )
			return HOOK_HANDLED;

		return HOOK_CONTINUE;
	}

	void pet_cmd_handle( SayParameters@ pParams )
	{
		if( g_cvarHideChat.GetInt() >= 1 )
			pParams.ShouldHide = true;

		const CCommand@ args = pParams.GetArguments();
		CBasePlayer@ pPlayer = pParams.GetPlayer();
		float flScale = args.ArgC() >= 3 ? atof(args.Arg(2)) : 0.0;

		if( args.ArgC() >= 2 ) // one arg supplied; off, menu, or petname
		{
			string szArg = args.Arg(1);
			if( szArg == "off" )
				removepet( pPlayer, false );
			else if( szArg == "menu" )
			{
				if( @petMenu is null )
				{
					@petMenu = CTextMenu(petMenuCallback);
					petMenu.SetTitle("Pet Menu: ");
					petMenu.AddItem( "<off>", null );
					array<string> petNames = g_petModels.getKeys();
					petNames.sortAsc();

					for( uint i = 0; i < petNames.length(); ++i )
						petMenu.AddItem( petNames[i].ToLowercase(), null );

					petMenu.Register();
				}

				petMenu.Open( 0, 0, pPlayer );
			}
			else
			{
				if( g_petModels.exists(szArg) )
					setpet( pPlayer, szArg, false, flScale );
				else
				{
					if( g_cvarHideInfo.GetInt() <= 0 )
						g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[PETS] Unknown pet. Try using \"pet menu\"?\n" );
					else
						g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] Unknown pet. Try using \"pet menu\"?\n" );
				}
			}
		}
	}

	void playerPostSpawn( int &in iIndex, string &in sSteamID )
	{
		CBasePlayer@ pPlayer = g_PlayerFuncs.FindPlayerByIndex( iIndex );
		if( pPlayer is null ) return;

		PetCrossover@ cData = cast<PetCrossover@>(g_petCrossover[sSteamID]);
		if( !cData.bCounted )
			setpet( pPlayer, cData.sPet, true, cData.flScale );
	}

	void ReadPets()
	{
		File@ file = g_FileSystem.OpenFile( g_petsFile, OpenFile::READ );

		if( file !is null and file.IsOpen() )
		{
			while( !file.EOFReached() )
			{
				string sLine;
				file.ReadLine(sLine);
				//fix for linux
				string sFix = sLine.SubString(sLine.Length()-1,1);
				if(sFix == " " or sFix == "\n" or sFix == "\r" or sFix == "\t")
					sLine = sLine.SubString(0, sLine.Length()-1);

				if( sLine.SubString(0,1) == "#" or sLine.IsEmpty() )
					continue;

				array<string> parsed = sLine.Split(" ");

				if( parsed.length() < 13 )
					continue;

				PetData pData;
				string sName = "";
				string sModelPath = "";
				float flScale = 1.0;
				int iIdleAnim = 0;
				float flIdleSpeed = 1.0;
				int iRunAnim = 0;
				float flRunSpeed = 1.0;
				int iDeathAnim = 0;
				float flDeathLength = 1.0;
				float flMinusZStanding = 0.0;
				float flMinusZCrouching = 0.0;
				float flMaxDistance = 0.0;
				float flMinDistance = 0.0;
				string sBoneControllers = "";

				sName = parsed[0];
				sModelPath = parsed[1];
				flScale = atof(parsed[2]);
				iIdleAnim = atoi(parsed[3]);
				flIdleSpeed = atof(parsed[4]);
				iRunAnim = atoi(parsed[5]);
				flRunSpeed = atof(parsed[6]);
				iDeathAnim = atoi(parsed[7]);
				flDeathLength = atof(parsed[8]);
				flMinusZStanding = atof(parsed[9]);
				flMinusZCrouching = atof(parsed[10]);
				flMaxDistance = atof(parsed[11]);
				flMinDistance = atof(parsed[12]);
				if( parsed.length() > 13 ) sBoneControllers = parsed[13];

				pData.sName = sName;
				pData.sModelPath = sModelPath;
				pData.flScale = flScale;
				pData.iIdleAnim = iIdleAnim;
				pData.flIdleSpeed = flIdleSpeed;
				pData.iRunAnim = iRunAnim;
				pData.flRunSpeed = flRunSpeed;
				pData.iDeathAnim = iDeathAnim;
				pData.flDeathLength = flDeathLength;
				pData.flMinusZStanding = flMinusZStanding;
				pData.flMinusZCrouching = flMinusZCrouching;
				pData.flMaxDistance = flMaxDistance;
				pData.flMinDistance = flMinDistance;
				pData.sBoneControllers = sBoneControllers;

				g_petModels[sName] = pData; 
			}

			file.Close();
		}
	}

	void setpet( CBasePlayer@ pPlayer, string sPet, bool bSilent, float flScale = 0.09 )
	{
		string sSteamID = g_EngineFuncs.GetPlayerAuthId( pPlayer.edict() );

		if( g_petUsers.exists(sSteamID) )
		{
			CBaseEntity@ pPet2 = cast<CBaseEntity@>(g_petUsers[sSteamID]);

			if( pPet2 !is null ) g_EntityFuncs.Remove(pPet2);
		}

		CBaseEntity@ pPet = g_EntityFuncs.Create( "info_target", pPlayer.pev.origin, pPlayer.pev.angles, true );
		g_EntityFuncs.DispatchSpawn(pPet.edict());
		PetData@ pData = cast<PetData@>(g_petModels[sPet]);
		PetCrossover cData;
		cData.sPet = sPet;
		cData.iCount = 0;
		cData.bCounted = true;
		g_EntityFuncs.SetModel( pPet, "models/" + pData.sModelPath + ".mdl" );

		Vector origin = pPlayer.pev.origin;
		if( IsUserCrouching(pPlayer) ) origin.z -= pData.flMinusZCrouching;
		else origin.z -= pData.flMinusZStanding;

		pPet.pev.origin = origin;

		if( flScale > 0.09 )
		{
			if( flScale > pData.flScale )
			{
				pPet.pev.scale = pData.flScale;
				g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] ERROR: scale must be between 0.1 and " + pData.flScale + " for this pet. Using default.\n" );
			}
			else pPet.pev.scale = flScale;
		}
		else pPet.pev.scale = pData.flScale;

		pPet.pev.solid = SOLID_NOT;
		pPet.pev.movetype = MOVETYPE_NOCLIP;
		//@pPet.pev.owner = pPlayer.edict();
		pPet.pev.nextthink = 1.0;
		pPet.pev.sequence = 0;
		pPet.pev.gaitsequence = 0;
		pPet.pev.framerate = 1.0;

		if( !pData.sBoneControllers.IsEmpty() )
		{
			array<string> parsed = pData.sBoneControllers.Split(":");

			for( uint i = 0; i < parsed.length() - 1; ++i )
				pPet.pev.set_controller(atoi(parsed[i]), atoi(parsed[i+1]));
		}

		cData.flScale = pPet.pev.scale;

		EHandle ePet = pPet;
		g_petUsers[sSteamID] = ePet;
		g_petUserPets[sSteamID] = pData.sName;
		g_petCrossover[sSteamID] = cData;

		if(!bSilent)
		{
			if(g_cvarHideInfo.GetInt() <= 0)
			{
				if( flScale > 0.0 and flScale < pData.flScale )
					g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[PETS] " + string(pPlayer.pev.netname) + " summoned a pet! (name: " + sPet + " - scale: " + pPet.pev.scale + ")\n" );
				else g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[PETS] " + string(pPlayer.pev.netname) + " summoned a pet! (name: " + sPet + ")\n" );
			}
			else
				g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] You summoned a pet! (name: " + sPet + ")\n" );
		}
	}

	bool removepet( CBasePlayer@ pPlayer, bool bSilent )
	{
		if( pPlayer is null ) return false;

		string sSteamID = g_EngineFuncs.GetPlayerAuthId( pPlayer.edict() );

		if( g_petUsers.exists(sSteamID) )
		{
			CBaseEntity@ pPet = cast<CBaseEntity@>(g_petUsers[sSteamID]);

			if( pPet !is null )
			{
				g_EntityFuncs.Remove(pPet);
				g_petUsers.delete(sSteamID);
				g_petUserPets.delete(sSteamID);

				if( g_petCrossover.exists(sSteamID) )
					g_petCrossover.delete(sSteamID);

				if(!bSilent)
				{
					if( g_cvarHideInfo.GetInt() <= 0 )
						g_PlayerFuncs.ClientPrintAll( HUD_PRINTTALK, "[PETS] " + string(pPlayer.pev.netname) + "'s pet has returned home.\n" );
					else
						g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] Your pet has returned home.\n" );
				}

				return true;
			}
			else
			{
				if(!bSilent) g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] Error: pet registered, but has invalid pet entity?\n" );

				return false;
			}
		}
		else
		{
			if(!bSilent) g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTTALK, "[PETS] You don't have a pet!\n" );

			return false;
		}
	}
	
	void petMenuCallback( CTextMenu@ mMenu, CBasePlayer@ pPlayer, int iPage, const CTextMenuItem@ mItem )
	{
		if( mItem !is null and pPlayer !is null )
		{
			if( mItem.m_szName == "<off>" )
				removepet( pPlayer, false );
			else
				setpet( pPlayer, mItem.m_szName, false );
		}
	}

	void PetThink()
	{
		CBasePlayer@ pPlayer = null;

		for( int i = 1; i <= g_Engine.maxClients; ++i )
		{
			@pPlayer = g_PlayerFuncs.FindPlayerByIndex(i);

			if( pPlayer !is null )
			{
				string sSteamID = g_EngineFuncs.GetPlayerAuthId( pPlayer.edict() );

				if( sSteamID == "" ) continue;

				if( g_petUsers.exists(sSteamID) )
				{
					CBaseEntity@ pPet = cast<CBaseEntity@>(g_petUsers[sSteamID]);

					if( pPet !is null )
					{
						int id = pPlayer.entindex();
						if( flTimeToDie[id] > 0 and g_Engine.time > flTimeToDie[id] )
						{
							flTimeToDie[id] = 0;
							if( bRemovePet[id] )
							{
								bRemovePet[id] = false;
								removepet( pPlayer, true );
							}

							continue;
						}

						string sPet = string(g_petUserPets[sSteamID]);
						PetData@ pData = cast<PetData@>(g_petModels[sPet]);

						Vector origin, origin2, velocity;

						origin2 = pPet.pev.origin;

						origin = get_offset_origin_body( pPlayer, Vector(50.0, 0.0, 0.0) );

						if( IsUserCrouching(pPlayer) ) origin.z -= pData.flMinusZCrouching;
						else origin.z -= pData.flMinusZStanding;

						if( (origin - origin2).Length() > pData.flMaxDistance )
							pPet.pev.origin = origin;
						else if( (origin - origin2).Length() > pData.flMinDistance )
						{
							velocity = get_speed_vector( origin2, origin, 250.0 );
							pPet.pev.velocity = velocity;

							if( (pPet.pev.sequence != pData.iRunAnim or pPet.pev.framerate != pData.flRunSpeed) and pPlayer.IsAlive() )
							{
								pPet.pev.frame = 1;
								pPet.pev.sequence = pData.iRunAnim;
								pPet.pev.gaitsequence = pData.iRunAnim;
								pPet.pev.framerate = pData.flRunSpeed;
							}
						}
						else if( (origin - origin2).Length() < pData.flMinDistance - 5.0 )
						{
							if( (pPet.pev.sequence != pData.iIdleAnim or pPet.pev.framerate != pData.flIdleSpeed) and pPlayer.IsAlive() )
							{
								pPet.pev.frame = 1;
								pPet.pev.sequence = pData.iIdleAnim;
								pPet.pev.gaitsequence = pData.iIdleAnim;
								pPet.pev.framerate = pData.flIdleSpeed;
							}

							pPet.pev.velocity = g_vecZero;
						}

						EHandle ePet = pPet;

						origin = pPlayer.pev.origin;
						origin.z = origin2.z;
						entity_set_aim( ePet, origin );

						pPet.pev.nextthink = g_Engine.time + 1.0;
					}
				}
			}
		}
	}

	void handle_death( CBasePlayer@ pPlayer, bool bDeletePet )
	{
		string sSteamID = g_EngineFuncs.GetPlayerAuthId( pPlayer.edict() );

		if( g_petUsers.exists(sSteamID) )
		{
			CBaseEntity@ pPet = cast<CBaseEntity@>(g_petUsers[sSteamID]);

			if( pPet !is null )
			{
				string sPet = string(g_petUserPets[sSteamID]);
				PetData@ pData = cast<PetData@>(g_petModels[sPet]);
				int id = pPlayer.entindex();

				pPet.pev.frame = 1;
				pPet.pev.animtime = 100.0;
				pPet.pev.sequence = pData.iDeathAnim;
				pPet.pev.gaitsequence = pData.iDeathAnim;

				flTimeToDie[id] = g_Engine.time + pData.flDeathLength;
				if( bDeletePet ) bRemovePet[id] = true;
			}
		}
	}

	bool IsUserCrouching( CBasePlayer@ pPlayer )
	{
		if( pPlayer !is null ) return (pPlayer.pev.flags & FL_DUCKING != 0);

		return false;
	}

	Vector get_offset_origin_body( CBasePlayer@ pPlayer, const Vector &in offset )
	{
		if( pPlayer is null ) return g_vecZero;

		Vector origin;

		Vector angles;
		angles = pPlayer.pev.angles;

		origin = pPlayer.pev.origin;

		origin.x += cos(angles.y * Math.PI / 180.0) * offset.x;
		origin.y += sin(angles.y * Math.PI / 180.0) * offset.x;

		origin.y += cos(angles.y * Math.PI / 180.0) * offset.y;
		origin.x += sin(angles.y * Math.PI / 180.0) * offset.y;

		return origin;
	}

	Vector get_speed_vector( const Vector &in origin1, const Vector &in origin2, const float &in speed )
	{
		Vector new_velocity;

		new_velocity.y = origin2.y - origin1.y;
		new_velocity.x = origin2.x - origin1.x;
		new_velocity.z = origin2.z - origin1.z;

		float num = sqrt( speed*speed / (new_velocity.y*new_velocity.y + new_velocity.x*new_velocity.x + new_velocity.z*new_velocity.z) );
		new_velocity.y *= num;
		new_velocity.x *= num;
		new_velocity.z *= num;

		return new_velocity;
	}

	void entity_set_aim( EHandle &in eEnt, const Vector &in origin2, int bone = 0 )
	{
		if( !eEnt.IsValid() ) return;

		CBaseEntity@ pEnt = eEnt.GetEntity();
		Vector origin, ent_origin, angles;

		origin = origin2;

		if( bone > 0 )
			g_EngineFuncs.GetBonePosition( pEnt.edict(), bone, ent_origin, angles );
		else
			ent_origin = pEnt.pev.origin;

		origin.x -= ent_origin.x;
		origin.y -= ent_origin.y;
		origin.z -= ent_origin.z;

		float v_length;
		v_length = origin.Length();

		Vector aim_vector;

		if( v_length > 0.0 )
		{
			aim_vector.x = origin.x / v_length;
			aim_vector.y = origin.y / v_length;
			aim_vector.z = origin.z / v_length;
		}
		else
			aim_vector = Vector(0, 90, 0);

		Vector new_angles;
		g_EngineFuncs.VecToAngles( aim_vector, new_angles );

		new_angles.x *= -1;

		if( new_angles.y > 180.0 ) new_angles.y -= 360;
		if( new_angles.y < -180.0 ) new_angles.y += 360;
		if( new_angles.y == 180.0 or new_angles.y == -180.0 ) new_angles.y = -179.999999;

		pEnt.pev.angles = new_angles;
		pEnt.pev.fixangle = 1;
	}

	void ReloadPetsCMD( const CCommand@ args )
	{
		CBasePlayer@ pPlayer = g_ConCommandSystem.GetCurrentPlayer();
		//Check for admin here instead of using SetMinimumAdminLevel ??
		g_petModels.deleteAll();
		ReadPets();
		g_PlayerFuncs.ClientPrint( pPlayer, HUD_PRINTCONSOLE, "[PETS] pets.txt reloaded succesfully?\n" );
	}
}

/*
*	Changelog
*
*	Version: 	1.0
*	Date: 		November 08 2017
*	-------------------------
*	- First release
*	-------------------------
*
*	Version: 	1.2
*	Date: 		November 22 2017
*	-------------------------
*	- Players can now specify the scale of their pet (up to the number specified in the config-file)
*	- Bone controllers can now be configured in pets.txt (for models that don't face the right way)
*	-------------------------
*
*    Version:     1.3
*    Date:         November 24 2017
*    -------------------------
*    - Pet scale is now saved to crossover data (for custom pet scaling)
*    -------------------------
*
*    Version:     1.3
*    Date:         December 20 2023
*    -------------------------
*    - Converted to normal plugin
*    -------------------------
*
*    Version:     1.3.1
*    Date:         17 February 2024
*    -------------------------
*    - Added .pets_reload command to make adjusting a pet's bone controllers smoother
*      Dont' use this when adding or removing pets, only for editing existing entries in pets.txt
*      Restart the map when adding or removing pets
*    -------------------------
*/

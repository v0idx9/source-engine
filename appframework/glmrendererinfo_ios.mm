//========= Copyright  1996-2009, Valve Corporation, All rights reserved. ============//
//
// Purpose: Defines a group of app systems that all have the same lifetime
// that need to be connected/initialized, etc. in a well-defined order
//
// $Revision: $
// $NoKeywords: $
//=============================================================================//

#include "GL/gl.h"

#undef MIN
#undef MAX
#include "tier0/threadtools.h"
#include "tier0/icommandline.h"
#include "tier1/interface.h"
#include "tier1/strtools.h"
#include "tier1/utllinkedlist.h"
#include "togl/rendermechanism.h"
#include "appframework/ilaunchermgr.h"	// gets pulled in from glmgr.h
#include "appframework/IAppSystemGroup.h"
#include "inputsystem/ButtonCode.h"

//===============================================================================

GLMRendererInfo::GLMRendererInfo( GLMRendererInfoFields *info )
{

	// absorb info obtained so far by caller
	m_info = *info;
	m_displays = NULL;
		
	// run queries.
	char *gl_ext_string = (char*)gGL->glGetString(GL_EXTENSIONS);

	uint vers = m_info.m_osComboVersion;
	// avoid crashing due to strstr'ing NULL pointer returned from glGetString
	if (!gl_ext_string)
	  gl_ext_string = "";

	
	//-------------------------------------------------------------------
	// booleans
	//-------------------------------------------------------------------
	// gamma writes.
	// OpenGL ES has no GL_FRAMEBUFFER_SRGB toggle, so glEnable( GL_FRAMEBUFFER_SRGB_EXT )
	// is an invalid enum under ANGLE and sRGB writes silently never happen (output stays
	// linear -> everything looks dark). Report "no gamma writes" so the translator appends
	// the fake-sRGB write suffix (flSRGBWrite uniform) to pixel shaders instead.
	m_info.m_hasGammaWrites = false;
	
	
	// extension string *could* be checked, but on 10.6.3 the ext string is not there, but the func *is*

	//-------------------------------------------------------------------
	// mixed attach sizes for FBO
	m_info.m_hasMixedAttachmentSizes = true;
		if (!strstr(gl_ext_string, "GL_ARB_framebuffer_object"))
		{
			// ARB_framebuffer_object not available
			m_info.m_hasMixedAttachmentSizes = false;
		}
	// also check ext string

	//-------------------------------------------------------------------
	// BGRA vert attribs
	m_info.m_hasBGRA = true;
	if (!strstr(gl_ext_string, "EXT_vertex_array_bgra"))
	{
		// EXT_vertex_array_bgra not available
		m_info.m_hasBGRA = false;
	}

	//-------------------------------------------------------------------
	m_info.m_hasNewFullscreenMode = true;
	//-------------------------------------------------------------------
	m_info.m_hasNativeClipVertexMode = false; //seems to cause some bugs with reflections when enabled?

	// if user disabled them
	if (CommandLine()->FindParm("-glmdisableclipplanes"))
	{
		m_info.m_hasNativeClipVertexMode = false;
	}
	
	// or maybe enabled them..
	if (CommandLine()->FindParm("-glmenableclipplanes"))
	{
		m_info.m_hasNativeClipVertexMode = true;
	}
	
	//-------------------------------------------------------------------
	m_info.m_hasOcclusionQuery = true;
	if (!strstr(gl_ext_string, "ARB_occlusion_query"))
	{
		m_info.m_hasOcclusionQuery = false;		// you don't got it!
	}
	
	//-------------------------------------------------------------------
	m_info.m_hasFramebufferBlit = true;
	if (!strstr(gl_ext_string, "EXT_framebuffer_blit"))
	{
		m_info.m_hasFramebufferBlit = false;	// you know you don't got it!
	}
	
	//-------------------------------------------------------------------
	m_info.m_maxAniso = 16;			//FIXME needs real query
	
	//-------------------------------------------------------------------
	m_info.m_hasBindableUniforms = true;
	if (!strstr(gl_ext_string, "EXT_bindable_uniform"))
	{
		m_info.m_hasBindableUniforms = false;
	}
	m_info.m_hasBindableUniforms = false;		// hardwiring this path to false until we see how to accelerate it properly
	
	//-------------------------------------------------------------------
	m_info.m_hasUniformBuffers = true;
	if (!strstr(gl_ext_string, "ARB_uniform_buffer"))
	{
		m_info.m_hasUniformBuffers = false;
	}

	//-------------------------------------------------------------------
	// test for performance pack (10.6.4+)

	bool perfPackageDetected = true;
	
	if (perfPackageDetected)
	{
		m_info.m_hasPerfPackage1 = true;
	}	

	if (CommandLine()->FindParm("-glmenableperfpackage"))	// force it on
	{
		m_info.m_hasPerfPackage1 = true;
	}
	
	if (CommandLine()->FindParm("-glmdisableperfpackage"))	// force it off
	{
		m_info.m_hasPerfPackage1 = false;
	}


	//-------------------------------------------------------------------
	// runtime options that aren't negotiable once set

	m_info.m_hasDualShaders = CommandLine()->FindParm("-glmdualshaders");

	//-------------------------------------------------------------------
	// "can'ts "
	
	m_info.m_cantBlitReliably = false;		//don't trust FBO blit on Intel before 10.6.6
	if (CommandLine()->FindParm("-glmenabletrustblit"))
	{
		m_info.m_cantBlitReliably = false;			// we trust the blit, so set the cant-blit cap to false
	}
	if (CommandLine()->FindParm("-glmdisabletrustblit"))
	{
		m_info.m_cantBlitReliably = true;			// we do not trust the blit, so set the cant-blit cap to true
	}

	m_info.m_cantAttachSRGB = false;	// across the board on 10.5.x actually..

	// MSAA resolve issues
	m_info.m_cantResolveFlipped	= false;	// initial stance
	

	m_info.m_cantResolveScaled = false;
	
	// gamma decode impacting shader codegen
	m_info.m_costlyGammaFlips = false;

	// The OpenGL driver for Intel HD4000 on 10.8 has a bug in the GLSL compiler, which was fixed
	// in 10.9 (and unlikely to be fixed in 10.8). See intelglmallocworkaround.h for more info.
	m_info.m_badDriver108Intel = false;

}

GLMRendererInfo::~GLMRendererInfo( void )
{
	if (m_displays)
	{
		// delete all the new'd renderer infos that the table tracks
		FOR_EACH_VEC( *m_displays, i )
		{
			delete (*this->m_displays)[i];
		}
		delete m_displays;
		m_displays = NULL;
	}
}

extern "C" int DisplayInfoSortFunction( GLMDisplayInfo* const *A, GLMDisplayInfo* const *B )
{
	int bigger = -1;
	int smaller = 1;	// adjust these to get the ordering you want

	// check main-ness - main should win

	uint maskOfMainDisplay = 1;
	//Assert( maskOfMainDisplay==1 );	// just curious
	
	int mainscreena = (*A)->m_info.m_glDisplayMask & maskOfMainDisplay;
	int mainscreenb = (*B)->m_info.m_glDisplayMask & maskOfMainDisplay;
	
	if ( mainscreena > mainscreenb )
	{
		return bigger;
	}
	else if ( mainscreena < mainscreenb )
	{
		return smaller;
	}
	
	// check area - larger screen should win
	int areaa = (*A)->m_info.m_displayPixelWidth * (*A)->m_info.m_displayPixelHeight;
	int areab = (*B)->m_info.m_displayPixelWidth * (*B)->m_info.m_displayPixelHeight;

	if ( areaa > areab )
	{	
		return bigger;
	}
	else if ( areaa < areab )
	{
		return smaller;
	}
	
	return 0;	// equal rank
}

void	GLMRendererInfo::PopulateDisplays( void )
{
	Assert( !m_displays );
	m_displays = new CUtlVector< GLMDisplayInfo* >;
	
		int numDisplays = SDL_GetNumVideoDisplays();
	
	for ( int i = 0; i < numDisplays; ++i )
	{
		SDL_DisplayMode mode;
		if ( SDL_GetCurrentDisplayMode( i, &mode ) == 0 )
		{
			CGDirectDisplayID dummyID = (CGDirectDisplayID)i;
			CGOpenGLDisplayMask dummyMask = (CGOpenGLDisplayMask)(1 << i);

			GLMDisplayInfo *newdisp = new GLMDisplayInfo( dummyID, dummyMask );
			m_displays->AddToTail( newdisp );
		}
	}
	
	// now sort the table of displays.
	m_displays->Sort( DisplayInfoSortFunction );

	// then go back and ask each display to populate its display mode table.
	FOR_EACH_VEC( *m_displays, i )
	{
		(*this->m_displays)[i]->PopulateModes();
	}
}


const char *CheesyRendererDecode( uint value )
{
	switch(value)
	{
		case 0x00020200 :  return "Generic";
		case 0x00020400 :  return "GenericFloat";
		case 0x00020600 :  return "AppleSW";
		case 0x00021000 :  return "ATIRage128";
		case 0x00021200 :  return "ATIRadeon";
		case 0x00021400 :  return "ATIRagePro";
		case 0x00021600 :  return "ATIRadeon8500";
		case 0x00021800 :  return "ATIRadeon9700";
		case 0x00021900 :  return "ATIRadeonX1000";
		case 0x00021A00 :  return "ATIRadeonX2000";
		case 0x00022000 :  return "NVGeForce2MX";
		case 0x00022200 :  return "NVGeForce3";
		case 0x00022400 :  return "NVGeForceFX";
		case 0x00022600 :  return "NVGeForce8xxx";
		case 0x00023000 :  return "VTBladeXP2";
		case 0x00024000 :  return "Intel900";
		case 0x00024200 :  return "IntelX3100";
		case 0x00040000 :  return "Mesa3DFX";

		default: return "UNKNOWN";
	}
}

extern const char *GLMDecode( GLMThing_t thingtype, unsigned long value );

void	GLMRendererInfo::Dump( int which )
{
	GLMPRINTF(("\n     #%d: GLMRendererInfo @ %08x, renderer-id=%s(%08x)  display-mask=%08x  vram=%dMB",
		which, this,
		CheesyRendererDecode( m_info.m_rendererID & 0x00FFFF00 ), m_info.m_rendererID,
		m_info.m_displayMask,
		m_info.m_vidMemory >> 20
	));
	GLMPRINTF(("\n       VendorID=%04x  DeviceID=%04x  Model=%s",
		m_info.m_pciVendorID,
		m_info.m_pciDeviceID,
		m_info.m_pciModelString
	));

	FOR_EACH_VEC( *m_displays, i )
	{
		(*m_displays)[i]->Dump(i);
	}
}


//===============================================================================


GLMDisplayDB::GLMDisplayDB	( void )
{
	m_renderers = NULL;	
}

GLMDisplayDB::~GLMDisplayDB	( void )
{
	if (m_renderers)
	{
		// delete all the new'd renderer infos that the table tracks
		FOR_EACH_VEC( *m_renderers, i )
		{
			delete (*this->m_renderers)[i];
		}
		delete m_renderers;
		m_renderers = NULL;
	}
}

extern "C" int RendererInfoSortFunction( GLMRendererInfo * const *A, GLMRendererInfo* const *B )
{
	int bigger = -1;
	int smaller = 1;
	
	// check VRAM
	if ( (*A)->m_info.m_vidMemory > (*B)->m_info.m_vidMemory )
	{	
		return bigger;
	}
	else if ( (*A)->m_info.m_vidMemory < (*B)->m_info.m_vidMemory )
	{
		return smaller;
	}
	
	// check MSAA limit
	if ( (*A)->m_info.m_maxSamples > (*B)->m_info.m_maxSamples )
	{	
		return bigger;
	}
	else if ( (*A)->m_info.m_maxSamples < (*B)->m_info.m_maxSamples )
	{
		return smaller;
	}
	

	return 0;	// equal rank
}

void	GLMDisplayDB::PopulateRenderers( void )
{
	Assert( !m_renderers );
	m_renderers = new CUtlVector< GLMRendererInfo* >;
	
	// now walk the renderer list
	// find the eligible ones and insert them into vector
	// if more than one, sort the vector by desirability with favorite at 0
	// then ask each renderer object to populate its displays

	// turns out how you have to do this is to walk the display mask 1<<n..
	// and query at each one, what renderers can hit that one.
	
	// when you find one, see if it's already in the vector above. if not, add it.
	// later, we sort them.

    GLMRendererInfoFields fields;
    memset(&fields, 0, sizeof(fields));

    fields.m_rendererID    = 0x01020304; // Dummy ID
    fields.m_displayMask   = 1;          // Only one display
    fields.m_fullscreen    = 1;
    fields.m_accelerated   = 1;
    fields.m_windowed      = 1;

    GLint maxSamples;
    gGL->glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
    fields.m_maxSamples = maxSamples;

    // iOS devices have unified memory; 512MB-1GB is a safe report for the engine
    fields.m_vidMemory = 512 * 1024 * 1024; 
    fields.m_texMemory = 512 * 1024 * 1024;

	GLMRendererInfo *newinfo = new GLMRendererInfo( &fields );
	m_renderers->AddToTail( newinfo );
	
	// now sort the table.
	m_renderers->Sort( RendererInfoSortFunction );

	// then go back and ask each renderer to populate its display info table.
	FOR_EACH_VEC( *m_renderers, i )
	{
		(*m_renderers)[i]->PopulateDisplays();
	}
}

void	GLMDisplayDB::PopulateFakeAdapters( uint realRendererIndex )		// fake adapters = one real adapter times however many displays are on it
{
	// presumption is that renderers have been populated.
	Assert( GetRendererCount() > 0 );
	Assert( realRendererIndex < GetRendererCount() );
	
	m_fakeAdapters.RemoveAll();
	
	// for( int r = 0; r < GetRendererCount(); r++ )
	int r = realRendererIndex;
	{
		for( int d = 0; d < GetDisplayCount( r ); d++ )
		{
			GLMFakeAdapter temp;
			
			temp.m_rendererIndex = r;
			temp.m_displayIndex = d;
			
			m_fakeAdapters.AddToTail( temp );
		}
	}
}

void	GLMDisplayDB::Populate(void)
{
	this->PopulateRenderers();
	
	// passing in zero here, constrains the set of fake adapters (GL renderer + a display) to the ones using the highest ranked renderer.
	//FIXME introduce some kind of convar allowing selection of other GPU's in the system.
	
	int realRendererIndex = 0;

	if (CommandLine()->FindParm("-glmrenderer0"))
		realRendererIndex = 0;
	if (CommandLine()->FindParm("-glmrenderer1"))
		realRendererIndex = 1;
	if (CommandLine()->FindParm("-glmrenderer2"))
		realRendererIndex = 2;
	if (CommandLine()->FindParm("-glmrenderer3"))
		realRendererIndex = 3;
		
	if (realRendererIndex >= GetRendererCount())
	{
		// fall back to 0
		realRendererIndex = 0;
	}
	
	this->PopulateFakeAdapters( 0 );

	#if GLMDEBUG
		this->Dump();
	#endif
}
	


int		GLMDisplayDB::GetFakeAdapterCount( void )
{
	return m_fakeAdapters.Count();
}

bool	GLMDisplayDB::GetFakeAdapterInfo( int fakeAdapterIndex, int *rendererOut, int *displayOut, GLMRendererInfoFields *rendererInfoOut, GLMDisplayInfoFields *displayInfoOut )
{
	if (fakeAdapterIndex >= GetFakeAdapterCount() )
	{
		*rendererOut = 0;
		*displayOut = 0;
		return true;		// fail
	}

	*rendererOut = m_fakeAdapters[fakeAdapterIndex].m_rendererIndex;
	*displayOut = m_fakeAdapters[fakeAdapterIndex].m_displayIndex;

	bool rendResult = GetRendererInfo( *rendererOut, rendererInfoOut );
	bool dispResult = GetDisplayInfo( *rendererOut, *displayOut, displayInfoOut );
	
	return rendResult || dispResult;
}
	

int		GLMDisplayDB::GetRendererCount( void )
{
	return	m_renderers->Count();
}

bool	GLMDisplayDB::GetRendererInfo( int rendererIndex, GLMRendererInfoFields *infoOut )
{
	memset( infoOut, 0, sizeof( GLMRendererInfoFields ) );

	if (rendererIndex >= GetRendererCount())
		return true; // fail
	
	GLMRendererInfo *rendInfo = (*m_renderers)[rendererIndex];		
	*infoOut = rendInfo->m_info;

	return false;
}

int		GLMDisplayDB::GetDisplayCount( int rendererIndex )
{
	if (rendererIndex >= GetRendererCount())
		return 0; // fail
	
	GLMRendererInfo *rendInfo = (*m_renderers)[rendererIndex];
		
	return	rendInfo->m_displays->Count();
}

bool	GLMDisplayDB::GetDisplayInfo( int rendererIndex, int displayIndex, GLMDisplayInfoFields *infoOut )
{
	memset( infoOut, 0, sizeof( GLMDisplayInfoFields ) );
	
	if (rendererIndex >= GetRendererCount())
		return true; // fail
	
	if (displayIndex >= GetDisplayCount(rendererIndex))
		return true; // fail
	
	GLMDisplayInfo *displayInfo = (*(*m_renderers)[rendererIndex]->m_displays)[displayIndex];
	*infoOut = displayInfo->m_info;

	return false;
}

int		GLMDisplayDB::GetModeCount( int rendererIndex, int displayIndex )
{
	if (rendererIndex >= GetRendererCount())
		return 0; // fail
	
	if (displayIndex >= GetDisplayCount(rendererIndex))
		return 0; // fail
		
	GLMDisplayInfo *displayInfo = (*(*m_renderers)[rendererIndex]->m_displays)[displayIndex];

	return displayInfo->m_modes->Count();
}

bool	GLMDisplayDB::GetModeInfo( int rendererIndex, int displayIndex, int modeIndex, GLMDisplayModeInfoFields *infoOut )
{
    if (modeIndex >= 0)
	{
        GLMDisplayMode *displayModeInfo = (*(*(*m_renderers)[rendererIndex]->m_displays)[displayIndex]->m_modes)[modeIndex];
        *infoOut = displayModeInfo->m_info;
        return false;
    } else
	{
        SDL_DisplayMode mode;
        if (SDL_GetCurrentDisplayMode(displayIndex, &mode) == 0) {
            infoOut->m_modePixelWidth = mode.w;
            infoOut->m_modePixelHeight = mode.h;
            infoOut->m_modeRefreshHz = mode.refresh_rate > 0 ? mode.refresh_rate : 60;
            
            GLMDisplayInfo *dispinfo = (*(*m_renderers)[rendererIndex]->m_displays)[displayIndex];
            FOR_EACH_VEC((*dispinfo->m_modes), i) {
                GLMDisplayMode *m = (*dispinfo->m_modes)[i];
                if (m->m_info.m_modePixelWidth == mode.w && m->m_info.m_modePixelHeight == mode.h) 
				{
                    *infoOut = m->m_info;
                    return false;
                }
            }
            return false;
        }
        return true;
    }
}


void	GLMDisplayDB::Dump( void )
{
	GLMPRINTF(("\n GLMDisplayDB @ %08x ",this ));

	FOR_EACH_VEC( *m_renderers, i )
	{
		(*m_renderers)[i]->Dump(i);
	}
}

//===============================================================================

GLMDisplayInfo::GLMDisplayInfo( CGDirectDisplayID displayID, CGOpenGLDisplayMask displayMask )
{	
	m_info.m_cgDisplayID			= displayID;
	m_info.m_glDisplayMask			= displayMask;
	
    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(displayID, &mode) == 0) 
	{
        int rw, rh;
        SDL_Window* pWindow = SDL_GetWindowFromID(1);
        
        if ( pWindow )
        {
            SDL_GetWindowSizeInPixels( pWindow, &rw, &rh );
            m_info.m_displayPixelWidth  = rw;
            m_info.m_displayPixelHeight = rh;
        }
        else
        {

            float scale = 3.0f; 
            m_info.m_displayPixelWidth  = mode.w * scale;
            m_info.m_displayPixelHeight = mode.h * scale;
        }
    } 
    else 
	{
        m_info.m_displayPixelWidth  = 1024; 
        m_info.m_displayPixelHeight = 768;
    }

	m_modes = NULL;
}


GLMDisplayInfo::~GLMDisplayInfo( void )
{
	if (m_modes)
	{
		// delete all the new'd display modes
		FOR_EACH_VEC( *m_modes, i )
		{
			delete (*this->m_modes)[i];
		}
		delete m_modes;
		m_modes = NULL;
	}
}


extern "C" int DisplayModeSortFunction( GLMDisplayMode * const *A, GLMDisplayMode * const *B )
{
	int bigger = -1;
	int smaller = 1;	// adjust these for desired ordering

	// check refreshrate - higher should win
	if ( (*A)->m_info.m_modeRefreshHz > (*B)->m_info.m_modeRefreshHz )
	{	
		return bigger;
	}
	else if ( (*A)->m_info.m_modeRefreshHz < (*B)->m_info.m_modeRefreshHz )
	{
		return smaller;
	}

	// check area - larger mode should win
	int areaa = (*A)->m_info.m_modePixelWidth * (*A)->m_info.m_modePixelHeight;
	int areab = (*B)->m_info.m_modePixelWidth * (*B)->m_info.m_modePixelHeight;

	if ( areaa > areab )
	{	
		return bigger;
	}
	else if ( areaa < areab )
	{
		return smaller;
	}
	
	return 0;	// equal rank
}

void GLMDisplayInfo::PopulateModes( void )
{
    Assert( !m_modes );
    m_modes = new CUtlVector< GLMDisplayMode* >;
    
    int rw, rh;
	SDL_DisplayMode mode;
    SDL_GetWindowSizeInPixels(SDL_GetWindowFromID(1), &rw, &rh);
	SDL_GetCurrentDisplayMode(0, &mode);
	//SDL_GetWindowSize(SDL_GetWindowFromID(1), &w, &h);
	float scale = (float)rw / mode.w;
    
	//hardcode all the modes we want to be available
	GLMDisplayMode *nativeMode = new GLMDisplayMode( rw, rh, mode.refresh_rate );
    m_modes->AddToTail( nativeMode );
	GLMDisplayMode *unscaled = new GLMDisplayMode( mode.w, mode.h, mode.refresh_rate );
    m_modes->AddToTail( unscaled );
	/*GLMDisplayMode *doubleunscaled = new GLMDisplayMode( mode.w * 2, mode.h * 2, mode.refresh_rate );
    m_modes->AddToTail( doubleunscaled );*/
	//for people with iPhone 69 pro max ultra 8k
	//actually bad idea as it might default to it
	/*GLMDisplayMode *fourtimesunscaled= new GLMDisplayMode( mode.w * scale + 1, mode.h * scale + 1, mode.refresh_rate );
    m_modes->AddToTail( fourtimesunscaled );*/

    int displayIndex = 0;
    int modeCount = 5;

    m_modes->Sort( DisplayModeSortFunction );
}


void	GLMDisplayInfo::Dump( int which )
{
	GLMPRINTF(("\n         #%d: GLMDisplayInfo @ %08x, cg-id=%08x  display-mask=%08x  pixwidth=%d  pixheight=%d", which, (int)(intp)this, m_info.m_cgDisplayID, m_info.m_glDisplayMask, m_info.m_displayPixelWidth,  m_info.m_displayPixelHeight ));

	FOR_EACH_VEC( *m_modes, i )
	{
		(*m_modes)[i]->Dump(i);
	}
}

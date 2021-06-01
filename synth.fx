/******************************************************************
 *  synth.fx for Reshade 4+ by kingeric1992
 *                                      update: June.1.2021
 ******************************************************************/

#define KEY_PAUSE 0x20 // space
#define KEY_RESET 0x52 // R


namespace synth
{
/******************************************************************
 *  assests
 ******************************************************************/

    uniform float   gFov        < ui_type="slider"; ui_min=1; ui_max=179; ui_step=1;>   = 75;

    uniform float   gMovSpeed   < ui_label="mov speed.";   ui_min = 0; ui_max = 10; > = 1;
    uniform float   gMseSpeed   < ui_label="mse sensitivity"; ui_min = 0; ui_max = 10; > = 0.1;

    uniform float   gPause      < source="key"; keycode = KEY_PAUSE; mode = "toggle";>;
    uniform bool    gForward    < source="key"; keycode = VK_W;>;
    uniform bool    gBack       < source="key"; keycode = VK_S;>;
    uniform bool    gLeft       < source="key"; keycode = VK_A;>;
    uniform bool    gRight      < source="key"; keycode = VK_D;>;
    uniform bool    gUp         < source="key"; keycode = VK_SPACE;>;
    uniform bool    gDown       < source="key"; keycode = VK_CONTROL;>;

    uniform float   gLMB        < source="mousebutton"; keycode = 0x00;>; //LMB
    uniform float   gRMB        < source="mousebutton"; keycode = 0x01;>; //RMB
    uniform float   gMMB        < source="mousebutton"; keycode = 0x04;>; //MMB
    uniform float2  gDelta      < source="mousedelta";>;
    uniform float2  gWheel      < source="mousewheel";>; // .y is delta
    uniform float   gFrameTime  < source="frametime";>;

    static const float2 gAspect = float2(BUFFER_HEIGHT * BUFFER_RCP_WIDTH,1);

    #define ADDRESS(a) AddressU = a; AddressV = a; AddressW = a
    #define FILTER(a)  MagFilter = a; MinFilter = a; MipFilter = a

    texture2D texCol  : COLOR;
    texture2D texEye { Format=RGBA32F; Width=2; };
    texture2D texUpd { Format=RGBA32F; Width=2; };
    texture2D texDep { Format=R32F; Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; };

    sampler2D sampCol { Texture=texCol; };
    sampler2D sampEye { Texture=texEye; FILTER(POINT); };
    sampler2D sampUpd { Texture=texUpd; FILTER(POINT); };
    sampler2D sampDep { Texture=texDep; FILTER(POINT); };

/******************************************************************
 *  helpers
 ******************************************************************/
    // float4x4 mWorld() {
    //     return float4x4( 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1);
    // }
    // float4x4 mView() {
    //     float2 t,p;
    //     float3 rot = tex2Dfetch(rot_s, 0).rgb;
    //     float3 eye = tex2Dfetch(eye_s, 0).rgb;
    //     sincos(rot.x * 6.28 ,t.x,t.y), sincos(-lerp(1.56, 0.1, rot.y),p.x,p.y);
    //     return mul(mul(
    //         float4x4( 1,0,0,0, 0,1,0,0, 0,0,-1,g_dist, 0,0,0,1),
    //         float4x4(1,0,0,0, 0,p.y,-p.x,0, 0,p.x,p.y,0, 0,0,0,1)),
    //         float4x4(t.y,-t.x,0,0, t.x,t.y,0,0, 0,0,1,0, 0,0,0,1)
    //     );
    // }
    float2   sincos(float r) { float2 sc; return sincos(r,sc.x,sc.y), sc; } // sin, cos
    float2   rotR(float2 p, float r) { float2 sc = sincos(r); return mul(float2x2(sc.y,-sc.x,sc), p); }
    float3x3 rotX(float r) { float2 sc = sincos(r); return float3x3( 1,0,0, 0,sc.y,-sc.x, 0,sc.x,sc.y); }
    float3x3 rotY(float r) { float2 sc = sincos(r); return float3x3( sc.y,0,sc.x, 0,1,0, -sc.x,0,sc.y); }
    float3x3 rotZ(float r) { float2 sc = sincos(r); return float3x3( sc.y,-sc.x,0, sc.x,sc.y,0, 0,0,1); }
    float3x3 rotZYX(float3 r) { return mul(mul(rotZ(r.x),rotX(PI-r.y)),rotZ(r.z)); }
    float2   map2D(uint id, float n) { float2 r; r.x = trunc(id/n), r.y = id - r.x * n; return r; }

    // world to view (unused)
    float4x4 getView( float3 _r, float3 _e) {
        float3x3 _m = rotZYX(_r);
        return float4x4(
            _m[0], -dot(_m[0],_e),
            _m[1], -dot(_m[1],_e),
            _m[2], -dot(_m[2],_e),
            0,0,0,1
        );
    }
    float4x4 mProj() {
        float zF = 20;
        float zN = 0.01;
        float t  = zN/(zF-zN);
        float sY = rcp(tan(radians(g_fov*.5)));
        float sX = sY * BUFFER_HEIGHT * BUFFER_RCP_WIDTH;
        return float4x4(sX,0,0,0, 0,sY,0,0, 0,0,-t,t*zF, 0,0,1,0);
    }

/******************************************************************
 *  controls
 ******************************************************************/

    // yaw pitch roll
    float3 getRot() { return tex2Dfetch(sampEye, int2(0,0)).xyz; }
    float3 getEye() { return tex2Dfetch(sampEye, int2(1,0)).xyz; }

    // roll when holding MMB
    float3 updRot( float3 rot) 
    {
        rot += mul(rotZYX(rot), float3( 
            gLMB*gDelta.xy, gMMB*atan2(gDelta.y,gDelta.x)) * gFrameTime * gMseSpeed * 0.01 );
        rot.x %= 2*PI;
        rot.yz = clamp(rot.yz, float2(0, -PI), PI);
        return rot;
    }
    float3 updEye( float3 rot ) 
    {
        float3 eye = rotZYX(rot);
        eye = mul(eye, float3( gRight - gLeft, 0, gBack - gForward)) + float3(0,0, gUp - gDown);
        return clamp(eye * gFrameTime * 0.01 * gMovSpeed + getEye(), -10, 10);
    }
    float4 vs_ctrl( uint vid : SV_VERTEXID ) : SV_POSITION { return float4( vid * 2. - 1.,0,0,1); }
    float3 ps_upd( float4 vpos : SV_POSITION ) : SV_TARGET
    {
        vpos.yzw = getRot(); return vpos.x < 1.? updRot(vpos.yzw) : updEye(vpos.yzw);
    }
    float3 ps_eye( float4 vpos : SV_POSITION ) : SV_TARGET
    {
        return gReset? (vpos.x < 1.? float3(0,PI/2,0) : float3(0,0,1)) : tex2Dfetch(sampTmp,vpos.xy).xyz
    }

/******************************************************************
 *  transforms
 ******************************************************************/

    float4 getPosP(uint vid, out float3 col, out float2 uv) {
        float4 pos;
        pos.xy = map2D(vid, BUFFER_WIDTH);
        pos.z  = dot( col = tex2Dfetch(sampCol, pos.xy).rgb, .333); // height by lum
        pos.w  = 1;
        uv = pos.xy * float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT); //uv = map2D(vid, 2);
        return pos;
    }
    float4 transform(float4 vpos) {
        return mul(mProj(),mul(getView(getRot() * float3(PI2, PI, PI2), getEye()),vpos));
    }

/******************************************************************
 *  shaders
 ******************************************************************/

    // depth map
    float4 vs_depth_p(uint vid : SV_VERTEXID) : SV_POSITION {
        float3 _; return transform(getPosP(vid, _, _.xy));
    }
    float  ps_depth( float4 vpos : SV_POSITION ) : SV_TARGET { return vpos.z; }

    // culling points in vs to stop init ps
    float4 vs_point(uint vid : SV_VERTEXID, out float3 col : TEXCOORD0) : SV_POSITION {
        float2 _;
        float4 pos = getPosP(vid, col, _), vpos = transform(pos);
        return vpos.z/vpos.w > tex2Dfetch(sampDep, pos.xy)? float4(0,0,-1,1) : vpos;
    }
    float4 ps_point( float4 vpos : SV_POSITION, float3 col : TEXCOORD0) : SV_TARGET { return col; }


    float4 vs_depth_l(uint vid : SV_VERTEXID) : SV_POSITION {
        float3 _; return transform(getPosL(vid, _, _.xy));
    }
    float4 vs_line(uint vid : SV_VERTEXID, out float3 col : TEXCOORD0) : SV_POSITION {
        float2 _; return transform(getPosL(vid, col, _));
    }
    // per pixel depth test
    float4 ps_line( float4 vpos : SV_POSITION, float3 col : TEXCOORD0) : SV_TARGET { 
        if(tex2Dfetch(sampDep, vpos.xy) > vpos.z) discard;
        return col; 
    }

/******************************************************************
 *  technique
 ******************************************************************/

    technique synth
    {
        pass upd {
            PrimitiveTopology   = LINELIST;
            VertexCount         = 2;
            VertexShader        = vs_ctrl;
            PixelShader         = ps_upd;
            RenderTarget        = texUpd;
        }
        pass eye {
            PrimitiveTopology   = LINELIST;
            VertexCount         = 2;
            VertexShader        = vs_ctrl;
            PixelShader         = ps_eye;
            RenderTarget        = texEye;
        }
    #ifdef LINES
        pass depth {
            VertexCount         = (LINESEG + 2) * LINEROW;
            PrimitiveTopology   = LINESTRIP;
            VertexShader        = vs_depth_l;
            PixelShader         = ps_depth;

            ClearRenderTargets  = true;
            RenderTarget	    = texDep;
            BlendEnable 	    = true;
            BlendOp			    = Min;
            DestBlend		    = ONE;
        }
        pass lines {
            VertexCount         = (LINESEG + 2) * LINEROW;
            PrimitiveTopology   = LINESTRIP;
            VertexShader        = vs_line;
            PixelShader         = ps_line;
        }
    #else
        pass depth {
            VertexCount         = BUFFER_WIDTH * BUFFER_HEIGHT;
            PrimitiveTopology   = POINTLIST;
            VertexShader        = vs_depth_p;
            PixelShader         = ps_depth;

            ClearRenderTargets  = true;
            RenderTarget	    = texDep;
            BlendEnable 	    = true;
            BlendOp			    = Min;
            DestBlend		    = ONE;
        }
        pass points {
            VertexCount         = BUFFER_WIDTH * BUFFER_HEIGHT;
            PrimitiveTopology   = POINTLIST;
            VertexShader        = vs_point;
            PixelShader         = ps_point;
        }
    #endif
    }
}

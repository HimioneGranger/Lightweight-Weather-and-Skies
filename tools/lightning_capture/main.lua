-- GPU capture harness. Loads the real mod Lua and GLSL directly from disk.
-- Only host/weather inputs, camera and neutral background are fixtures.
local root,out,limit,family
local W,H,FPS=960,540,30
local function write(path,bytes)
  local f=assert(io.open(path,'wb'));f:write(bytes);f:close()
end
local function read(path)
  local f=assert(io.open(path,'rb'));local b=f:read('*a');f:close();return b
end
local function mul(a,b)
  local m={}
  for r=0,3 do for c=0,3 do local v=0
    for k=0,3 do v=v+a[r*4+k+1]*b[k*4+c+1]end
    m[r*4+c+1]=v
  end end
  return m
end
local function camera(pitch)
  local c,s=math.cos(pitch),math.sin(pitch)
  local view={1,0,0,0, 0,c,s,-40*c, 0,-s,c,40*s, 0,0,0,1}
  local n,f=1,300000;local t=1/math.tan(math.rad(65)/2)
  -- LOVE's canvas clip convention needs negative Y for world-up to screen-up.
  local proj={t/(W/H),0,0,0, 0,-t,0,0, 0,0,-(f+n)/(f-n),-2*f*n/(f-n), 0,0,-1,0}
  return {eye={0,40,0},focus={0,40,-100},far=f,vp=mul(proj,view)}
end
function love.load(args)
  print('LWS capture load',unpack(args or {}))
  root=assert(args[1],'source root required'):gsub('\\','/')
  out=assert(args[2],'output directory required'):gsub('\\','/')
  limit=tonumber(args[3])
  family=args[4]
  local ok,err=xpcall(function()
    love.window.setMode(W,H,{vsync=0,msaa=0,resizable=false})
    love.window.setTitle('LWS actual GPU capture')
    love.window.minimize()
    local g=love.graphics
    local renderer,version,vendor,device=g.getRendererInfo()
    local logs={'LWS actual GPU capture',renderer,version,vendor,device,
      'Source: '..root,'960x540, 4x MSAA, 30 fps, original timing, natural FULL brightness',
      'Loads QuestStorm.lua, QuestStormBolt.lua, Gen2VoxelClouds.lua and cloud sources directly.'}
    local sources={}
    local function loadmod(path,V)
      sources[path]=love.data.encode('string','hex',love.data.hash('sha256',read(root..'/'..path)))
      return assert(loadfile(root..'/'..path))(V)
    end
    local scene={now={mapId='ROUTE_29',outdoor=true,indoors=false,visible='world'}}
    local weather={id='STORM',level=1,current=function()return {ch={rain=1}}end,
      channel=function(k)return ({rain=1,dim=.34,gust=.8})[k]or 0 end}
    local modules={Scene=scene,WeatherState=weather,QuestAfterStorm={cloud=0},
      QuestStormFront={managed=false,coverage=1,warning=0,cloudField=function()return nil end},
      OutdoorWeatherAreas={identity=function(id)return id end},
      QuestRegional={lightningRate=function()return 1 end}}
    local V={mod={exports={weatherPreferences={storm=function()return {mode='full',pace='rare'}end}}}}
    V.require=function(name)return assert(modules[name],name)end
    V.mod.read=function(_,path)
      local bytes=read(root..'/'..path)
      sources[path]=love.data.encode('string','hex',love.data.hash('sha256',bytes))
      return bytes
    end
    local oldTime=os.time;os.time=function()return 1700000000 end
    local storm=loadmod('lib/QuestStorm.lua',V);os.time=oldTime
    modules.QuestStorm=storm
    local bolt=loadmod('lib/QuestStormBolt.lua',V)
    local voxel=camera(math.rad(32));storm.bindCamera(voxel)
    local host={require=function(name)
      if name=='DayNight' then return {time=function()return 800 end,
        tint=function()return storm.tint({.46,.50,.62},true,true)end}end
      if name=='Sky' then return {haze=function()return {.08,.10,.16}end}end
      error(name)
    end}
    local cloud=loadmod('lib/Gen2VoxelClouds.lua',V).new(host,voxel)
    for i=1,600 do cloud:update(.1)end
    local canvas=g.newCanvas(W,H,{format='rgba8',msaa=4})
    local titleFont=g.newFont(18);local smallFont=g.newFont(13)
    local settings={worldWeatherEnabled=function()return true end}
    local shots={{'anvil',91221,1},{'anvil',418821,2},{'anvil',717119,3},
      {'forked',81931,1},{'forked',53219,2}}
    for _,shot in ipairs(shots)do
      local kind,seed,num=unpack(shot)
      if (not family or kind==family) and (not limit or (kind=='anvil' and num==1))then
        voxel.vp=camera(math.rad(kind=='anvil' and 32 or 20)).vp
        storm.reset();storm.seed=seed;storm.strength=1
        storm.update(1/FPS,weather,settings)
        assert(storm.triggerTest(kind),'preview trigger failed')
        local frames=limit or (kind=='anvil' and 105 or 66)
        local peak,peakFrame=0,0
        for frame=0,frames-1 do
          if frame>=9 then storm.update(1/FPS,weather,settings)end
          cloud:update(1/FPS)
          local e=storm.bolt()
          if e and e.boltAlpha>peak then peak=e.boltAlpha;peakFrame=frame end
          if e and frame==9 then
            logs[#logs+1]=('%s%d id=%d profile=%d branches=%d vertices=%d verification=%s'):format(
              kind,num,e.id,e.variant.id,#(e.branches or {}),#bolt.vertices(e),tostring(e.verification))
          end
          g.setCanvas({canvas,depth=true});g.clear(.035,.05,.09,1,0,1)
          g.origin();g.setShader();g.setDepthMode();g.setColor(1,1,1,1)
          assert(cloud:draw({id='ROUTE_29'},nil,true),'cloud draw failed')
          bolt.drawWorld(voxel)
          g.setShader();g.setDepthMode();g.setColor(.018,.025,.045,1)
          g.rectangle('fill',0,0,W,57);g.rectangle('fill',0,H-31,W,31)
          g.setColor(.90,.95,1,1);g.setFont(titleFont)
          g.print((kind=='anvil' and 'ANVIL CRAWLER' or 'GROUND STRIKE')..' / '..num,18,9)
          g.setColor(.62,.71,.83,1);g.setFont(smallFont)
          g.print('Live mod Lua + GPU shaders | FULL, normal speed | fixed camera',18,34)
          g.print('Isolated engine capture - actual lightning and cloud renderer',18,H-23)
          g.setCanvas()
          local data=canvas:newImageData();local encoded=data:encode('png')
          write(('%s/%s%d_%03d.png'):format(out,kind,num,frame),encoded:getString())
          data:release();encoded:release()
          if frame%15==0 then love.event.pump()end
        end
        logs[#logs+1]=('%s%d frames=%d peakFrame=%d peakAlpha=%.6f'):format(kind,num,frames,peakFrame,peak)
      end
    end
    for path,hash in pairs(sources)do logs[#logs+1]=hash..' '..path end
    write(out..'/capture-receipt.txt',table.concat(logs,'\n')..'\n')
  end,debug.traceback)
  if not ok then write(out..'/capture-error.txt',tostring(err))end
  love.event.quit(ok and 0 or 1)
end
function love.errorhandler(msg)
  print('LWS capture fatal: '..tostring(msg))
  if out then write(out..'/capture-error.txt',tostring(msg))end
  return function()return 1 end
end

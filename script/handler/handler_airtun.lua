

local airtun = {}

-- 加载必要的库
_G.sys = require("sys")
require("pins")
require("mqtt")
require("misc") 
require "util_mobile"
require "handler_call"
require "util_notify"

module(..., package.seeall)

-- MQTT 客户端实例
local mqttc

-- 本机号码
local phone_number = util_mobile.getNumber()

-- MQTT 配置
local mqtt_host = "mqtt.air32.cn"
local mqtt_port = 1883
local mqtt_client_id = misc.getImei()

-- 主题
local topic_up
local topic_down

-- LED控制
local LED = pins.setup(27, 0)

-- 处理收到的消息
local function handleMessage(packet)
    log.info("airtun", "收到消息", packet.topic, packet.payload)
    local jdata = json.decode(packet.payload)

    if jdata and jdata.action then
        if jdata.action == "req" then
            -- Http请求处理
            if jdata.req and jdata.req.uri then
                -- 处理其他 API 请求 
                if jdata.req.uri == "/api/action" then
                    -- 处理直接的命令消息
                    local req = jdata.req.json
                    if req.command == "call" then
                        log.info("airtun", "收到拨打电话命令")
                        local playAmr = false
                        if req.sendSms and req.sendSms == "true" then
                            -- 发送短信
                            util_mobile.sendSms(req.phone, req.message)
                        end
                        if req.voice and req.voice ~= "" then
                            -- 将base64编码的AMR语音数据解码并保存
                            local voiceData = crypto.base64_decode(req.voice, #req.voice)
                            if voiceData then
                                local amrFile = "/lua/temp.amr"
                                local file = io.open(amrFile, "wb")
                                if file then
                                    file:write(voiceData)
                                    file:close()
                                    playAmr = true
                                end
                            end
                        end
                        handler_call.dialAndPlayTts(req.phone, req.message, playAmr)
                    elseif req.command == "queryTraffic" then
                        log.info("airtun", "收到查询流量命令")
                        util_mobile.queryTraffic() 
                    elseif req.command == "queryBalance" then
                        log.info("airtun", "收到查询话费余额命令")
                        util_mobile.queryBalance()
                    elseif req.command == "sendSms" then
                        log.info("airtun", "收到发送短信命令")
                        util_mobile.sendSms(req.phone, req.message)
                    elseif json.command == "status" then
                        log.info("airtun", "收到状态通知")
                        mqttc:publish(topic_up .. "/status", "#BOOT_" .. rtos.poweron_reason() .. util_notify.BuildDeviceInfo(), 1)
                    end
                end
            end

            return airtun_resp_json(jdata.req.id, 200, nil, {ok=true})
        elseif jdata.action == "ping" then
            -- 回应ping
            mqttc:publish(topic_up, json.encode({action = "pong"}), 1)
        end
    else
        
    end
 
end

-- 连接MQTT服务器的函数
local function connectMqtt()
    -- 初始化 MQTT 客户端
    mqttc = mqtt.client(mqtt_client_id, 300)
    
    -- 尝试连接服务器
    if mqttc:connect(mqtt_host, mqtt_port, "tcp",nil,10000) then
        log.info("airtun", "连接成功")
        
        -- 订阅主题
        mqttc:subscribe({
            [topic_down] = 0
        })

        -- 发送上线消息
        local msg = {
            action = "conn",
            conn = {
                device = misc.getImei(),
                number = phone_number
            }
        }
        mqttc:publish(topic_up, json.encode(msg), 1)
        return true
    else
        log.error("airtun", "连接失败")
        mqttc = nil
        return false
    end
end

-- 启动 MQTT 客户端
sys.taskInit(function()
    log.info("airtun", "初始化")
    
    -- 等待网络就绪（减少到10秒）
    sys.waitUntil("IP_READY", 10000)

    -- 初始化主题
    local device_id = misc.getImei():lower()
    topic_up = "$airtun/" .. device_id .. "/up"
    topic_down = "$airtun/" .. device_id .. "/down"

    log.info("airtun", "topic up", topic_up)
    log.info("airtun", "topic down", topic_down)
    log.info("airtun", "===========================================")
    log.info("airtun", "访问地址", "https://" .. device_id .. ".airtun.air32.cn")
    log.info("airtun", "===========================================")

    -- 主循环
    while true do
        -- 如果没有连接，尝试连接
        if not mqttc then
            if not connectMqtt() then
                sys.wait(2000)  -- 等待2秒后重试（从5秒减少到2秒）
            end
        end

        -- 如果已连接，处理消息
        if mqttc then
            local result, packet = mqttc:receive(3000)
            if result then
                handleMessage(packet)
            else
                -- 检查连接状态并发送心跳
                if mqttc.connected then
                    -- mqttc:publish(topic_up, json.encode({action = "ping"}), 1)
                    log.info("airtun", "在线")
                else
                    log.error("airtun", "连接断开")
                    mqttc = nil  -- 重置连接，下次循环会重新连接
                end
            end
        end
    end
end)


function airtun_resp(id, code, headers, body)
    log.info("airtun_resp mqttc.connected", mqttc and mqttc.connected or "nil", id)
    if mqttc and mqttc.connected then
        local msg = {action="resp"} 
        msg["resp"] = {id=id, code=code, headers=headers, body=body}
        local payload = json.encode(msg)
        log.info("airtun#payload", payload)
        local send = mqttc:publish(topic_up, payload, 1)
        log.info("airtun#payload#send", send)
        if not send then
            log.error("airtun", "airtun_resp publish failed")
            -- Reset MQTT connection on error
            mqttc = nil
        end
    else
        log.warn("airtun", "Cannot send response - MQTT not connected")
    end
end

function airtun_resp_json(id, code, headers, body)
    headers = headers or {}
    headers["Content-Type"] = "appilcation/json"
    body = json.encode(body)
    airtun_resp(id, code, headers, body)
end

return airtun
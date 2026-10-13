import sys
T = {
 'Bạn đã thu hồi một tin nhắn': {'en':'You unsent a message','ko':'메시지를 회수했어요','ja':'メッセージの送信を取り消しました','th':'คุณยกเลิกการส่งข้อความแล้ว','zh':'你撤回了一条消息'},
 'Cuộc gọi thoại': {'en':'Voice call','ko':'음성 통화','ja':'音声通話','th':'โทรด้วยเสียง','zh':'语音通话'},
 'Cuộc gọi đang diễn ra': {'en':'Call in progress','ko':'통화 중','ja':'通話中','th':'กำลังโทรอยู่','zh':'通话进行中'},
 'Cuộc họp nội bộ Flygo Chat': {'en':'Flygo Chat internal meeting','ko':'Flygo Chat 내부 회의','ja':'Flygo Chat 社内会議','th':'การประชุมภายใน Flygo Chat','zh':'Flygo Chat 内部会议'},
 'Cuộc họp đang diễn ra': {'en':'Meeting in progress','ko':'회의 진행 중','ja':'会議中','th':'กำลังประชุมอยู่','zh':'会议进行中'},
 'Cuộc họp đã kết thúc': {'en':'Meeting ended','ko':'회의가 종료됐어요','ja':'会議が終了しました','th':'การประชุมสิ้นสุดแล้ว','zh':'会议已结束'},
 'Không sửa được tin. Kiểm tra kết nối mạng.': {'en':"Couldn't edit the message. Check your connection.",'ko':'메시지를 수정하지 못했어요. 네트워크 연결을 확인해 주세요.','ja':'メッセージを編集できませんでした。ネットワーク接続を確認してください。','th':'แก้ไขข้อความไม่สำเร็จ โปรดตรวจสอบการเชื่อมต่อ','zh':'无法编辑消息，请检查网络连接。'},
 'Mọi người trong cuộc trò chuyện sẽ thấy "Tin nhắn đã được thu hồi".': {'en':'Everyone in the chat will see "This message was unsent".','ko':'대화의 모든 사람에게 "회수된 메시지입니다"로 표시돼요.','ja':'トークの全員に「このメッセージは取り消されました」と表示されます。','th':'ทุกคนในแชทจะเห็น "ข้อความนี้ถูกยกเลิกการส่งแล้ว"','zh':'聊天中的所有人都会看到“此消息已撤回”。'},
 'Mời tham gia cuộc họp': {'en':'Meeting invitation','ko':'회의 초대','ja':'会議への招待','th':'คำเชิญเข้าร่วมประชุม','zh':'会议邀请'},
 'Sửa tin nhắn': {'en':'Edit message','ko':'메시지 수정','ja':'メッセージを編集','th':'แก้ไขข้อความ','zh':'编辑消息'},
 'Tham gia': {'en':'Join','ko':'참여','ja':'参加','th':'เข้าร่วม','zh':'加入'},
 'Tham gia cuộc họp': {'en':'Join meeting','ko':'회의 참여','ja':'会議に参加','th':'เข้าร่วมประชุม','zh':'加入会议'},
 'Thu hồi': {'en':'Unsend','ko':'회수','ja':'送信取消','th':'ยกเลิกการส่ง','zh':'撤回'},
 'Thu hồi tin nhắn này?': {'en':'Unsend this message?','ko':'이 메시지를 회수할까요?','ja':'このメッセージの送信を取り消しますか？','th':'ยกเลิกการส่งข้อความนี้ไหม?','zh':'撤回这条消息？'},
 'Tin nhắn đã được thu hồi': {'en':'This message was unsent','ko':'회수된 메시지입니다','ja':'このメッセージは取り消されました','th':'ข้อความนี้ถูกยกเลิกการส่งแล้ว','zh':'此消息已撤回'},
 '{0} giây': {'en':'{0} sec','ko':'{0}초','ja':'{0}秒','th':'{0} วินาที','zh':'{0} 秒'},
 '{0} giờ {1} phút': {'en':'{0} hr {1} min','ko':'{0}시간 {1}분','ja':'{0}時間{1}分','th':'{0} ชม. {1} นาที','zh':'{0} 小时 {1} 分钟'},
 '{0} phút {1} giây': {'en':'{0} min {1} sec','ko':'{0}분 {1}초','ja':'{0}分{1}秒','th':'{0} นาที {1} วินาที','zh':'{0} 分 {1} 秒'},
 '{0} đã bắt đầu · {1}': {'en':'{0} started · {1}','ko':'{0}님이 시작함 · {1}','ja':'{0}が開始 · {1}','th':'{0} เริ่มแล้ว · {1}','zh':'{0} 发起 · {1}'},
}
import re
def esc(x): return x.replace('\\','\\\\').replace("'","\\'")
for l in ['en','ko','ja','th','zh']:
    p=f'lib/i18n/{l}.dart'; s=open(p).read().rstrip()
    have=set(m.group(1) for m in re.finditer(r"^\s*'((?:[^'\\]|\\.)*)'\s*:", s, re.M))
    add=''.join(f"  '{esc(k)}': '{esc(v[l])}',\n" for k,v in T.items() if esc(k) not in have)
    s=s[:-2].rstrip()+'\n'+add+'};\n'
    open(p,'w').write(s)
print('ok')

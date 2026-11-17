import { NativeHostEvent, NativeQuestion, NativeQuestionOption, NativeAnswer } from '../data/NativeDto';
import { appStore } from '../state/AppStore';
import { GAP_NORMAL, GAP_LARGE, RADIUS_CARD } from '../common/Style';

@Component
export struct HostQuestions {
  @Prop request: NativeHostEvent = new NativeHostEvent();
  @State selected: Map<string, string[]> = new Map();
  @State custom: Map<string, string> = new Map();
  @State busy: boolean = false;
  @State error: string = '';
  @State remainingMs: number = -1;
  @State waitReady: boolean = false;
  private waitId: string = '';

  aboutToAppear(): void {
    if (this.request.timed) {
      try {
        this.waitId = appStore.claimQuestionWait(this.request.eventId, (remaining: number) => {
          this.remainingMs = remaining; this.waitReady = true;
        }, () => { this.waitReady = false; this.error = '等待连接已失效，请刷新或在主机上回答'; });
      } catch (_) { this.error = '该问题暂不能在此回答，请在主机上处理'; }
    } else this.waitReady = true;
  }
  aboutToDisappear(): void { if (this.waitId) appStore.releaseQuestionWait(this.waitId); }
  private choose(question: NativeQuestion, label: string, checked: boolean): void {
    const values = this.selected.get(question.id) || [];
    const next = question.multiSelect ? values.filter((value: string): boolean => value !== label) : [];
    if (checked) next.push(label);
    const map = new Map(this.selected); map.set(question.id, next); this.selected = map;
  }
  private async answer(): Promise<void> {
    this.busy = true; this.error = '';
    const answers: NativeAnswer[] = this.request.questions.map((question: NativeQuestion): NativeAnswer => {
      const answer = new NativeAnswer(); answer.id = question.id;
      answer.selected = this.selected.get(question.id) || []; answer.custom = this.custom.get(question.id) || '';
      return answer;
    });
    try { await appStore.answerQuestion(this.request.eventId, answers); }
    catch (_) { this.error = '主机未确认答复，请检查连接与问题是否仍有效'; }
    finally { this.busy = false; }
  }
  build() {
    Column({ space: GAP_LARGE }) {
      Text('主机需要你回答').fontSize(16).fontWeight(FontWeight.Medium)
      if (this.remainingMs >= 0) { Text('主机剩余等待时间：' + Math.ceil(this.remainingMs / 1000) + ' 秒').fontSize(12) }
      ForEach(this.request.questions, (question: NativeQuestion) => {
        Column({ space: GAP_NORMAL }) {
          Text(question.question).fontSize(14).width('100%')
          if (question.detail) { Text(question.detail).fontSize(12).fontColor($r('app.color.text_secondary')) }
          ForEach(question.options, (option: NativeQuestionOption) => {
            Row({ space: GAP_NORMAL }) {
              if (question.multiSelect) {
                Checkbox().select((this.selected.get(question.id) || []).indexOf(option.label) >= 0)
                  .onChange((checked: boolean) => { this.choose(question, option.label, checked); })
              } else {
                Radio({ value: option.label, group: this.request.eventId + question.id })
                  .checked((this.selected.get(question.id) || []).indexOf(option.label) >= 0)
                  .onChange((checked: boolean) => { this.choose(question, option.label, checked); })
              }
              Column({ space: 2 }) {
                Text(option.label).fontSize(14)
                if (option.description) { Text(option.description).fontSize(12).fontColor($r('app.color.text_secondary')) }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%')
          }, (option: NativeQuestionOption) => option.label)
          TextInput({ text: this.custom.get(question.id) || '', placeholder: '补充回答（可选）' })
            .onChange((value: string) => { const map = new Map(this.custom); map.set(question.id, value); this.custom = map; })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }, (question: NativeQuestion) => question.id)
      Text('留空的问题将跳过，不会作为授权。').fontSize(12).fontColor($r('app.color.text_secondary'))
      if (this.error) { Text(this.error).fontSize(12).fontColor($r('app.color.danger')) }
      Button(this.busy ? '正在提交…' : '提交回答').enabled(!this.busy && this.waitReady)
        .width('100%').onClick(() => { this.answer(); })
    }
    .width('100%').padding(GAP_LARGE).borderRadius(RADIUS_CARD)
    .alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.surface'))
  }
}

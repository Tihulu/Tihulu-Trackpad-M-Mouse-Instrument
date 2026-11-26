#if os(iOS)
import SwiftUI
import UIKit
import NoSpeakerCore

/// Local UIKit multi-touch diagnostic surface. No camera, audio or MIDI.
@MainActor struct MobileTouchPianoPreview:UIViewControllerRepresentable {
    func makeUIViewController(context:Context)->MobileTouchPianoController {
        MobileTouchPianoController()
    }
    func updateUIViewController(_ uiViewController:MobileTouchPianoController,context:Context){}
    static func dismantleUIViewController(_ uiViewController:MobileTouchPianoController,coordinator:()){
        uiViewController.retire()
    }
}

@MainActor final class MobileTouchPianoController:UIViewController {
    private let piano=MobileTouchPianoView(frame:.zero)
    private let status=UILabel()
    private let armButton=UIButton(type:.system)
    private let releaseButton=UIButton(type:.system)
    override func viewDidLoad(){
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let detail=UILabel()
        detail.text="Local logical-key preview · up to ten contacts · no sound or MIDI"
        detail.numberOfLines=0
        status.numberOfLines=0
        status.text="Stopped. Press Arm to begin."
        armButton.setTitle("Arm piano",for:.normal)
        releaseButton.setTitle("Release all / stop",for:.normal)
        releaseButton.isEnabled=false
        armButton.addTarget(self,action:#selector(arm),for:.touchUpInside)
        releaseButton.addTarget(self,action:#selector(retire),for:.touchUpInside)
        piano.changed={ [weak self] output,armed in
            guard let self else{return}
            let keys=(0..<25).filter{output.keys & (1<<$0) != 0}
            self.status.text = !armed ? "Stopped. Press Arm to begin." :
                keys.isEmpty ? "Ready · no held keys" : "Held logical keys: "+keys.map{String($0+1)}.joined(separator:", ")
            self.armButton.isEnabled = !armed
            self.releaseButton.isEnabled = armed
        }
        let stack=UIStackView(arrangedSubviews:[detail,status,piano,armButton,releaseButton])
        stack.axis = .vertical
        stack.spacing=12
        stack.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(stack)
        let guide=view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo:guide.topAnchor,constant:16),
            stack.bottomAnchor.constraint(equalTo:guide.bottomAnchor,constant:-16),
            stack.leadingAnchor.constraint(equalTo:guide.leadingAnchor,constant:16),
            stack.trailingAnchor.constraint(equalTo:guide.trailingAnchor,constant:-16),
            piano.heightAnchor.constraint(greaterThanOrEqualToConstant:100)
        ])
        status.setContentHuggingPriority(.required,for:.vertical)
        detail.setContentHuggingPriority(.required,for:.vertical)
        armButton.setContentHuggingPriority(.required,for:.vertical)
        releaseButton.setContentHuggingPriority(.required,for:.vertical)
        NotificationCenter.default.addObserver(self,selector:#selector(inactive(_:)),name:UIApplication.willResignActiveNotification,object:nil)
    }
    @objc private func inactive(_ notification:Notification){retire()}
    @objc private func arm(){piano.arm()}
    @objc func retire(){piano.retire()}
    override func viewWillDisappear(_ animated:Bool){retire();super.viewWillDisappear(animated)}
}

@MainActor final class MobileTouchPianoView:UIView {
    private let authorized=(1<<13)-1
    private var owner:MobileTouchOwnership?
    private var contacts:[ObjectIdentifier:(Int,UITouch)]=[:]
    private var priorSize=CGSize.zero
    var changed:((MobileAirOutput,Bool)->Void)?
    override init(frame:CGRect){
        super.init(frame:frame)
        isMultipleTouchEnabled=true
        isAccessibilityElement=true
        accessibilityLabel="Thirteen logical piano zones; use multiple fingers. Visual preview only."
        backgroundColor = .secondarySystemBackground
        contentMode = .redraw
    }
    required init?(coder:NSCoder){return nil}
    func arm(){
        guard owner==nil,window?.windowScene?.activationState == .foregroundActive,UIApplication.shared.applicationState == .active,
              bounds.width>0,bounds.height>0 else{return}
        contacts.removeAll()
        owner=MobileTouchOwnership(authorized:authorized)
        changed?(.init(),true);setNeedsDisplay()
    }
    func retire(){
        guard owner != nil else{return}
        owner=nil;contacts.removeAll()
        changed?(.init(),false);setNeedsDisplay()
    }
    override func didMoveToWindow(){
        super.didMoveToWindow()
        if window==nil{retire()}
    }
    override func layoutSubviews(){
        super.layoutSubviews()
        let size=bounds.size
        if priorSize.width>0,priorSize.height>0,size != priorSize{retire()}
        priorSize=size
    }
    private func publish(_ change:MobileTouchOwnership.Change){
        guard var current=owner,bounds.width>0,bounds.height>0,
              window?.windowScene?.activationState == .foregroundActive,UIApplication.shared.applicationState == .active else{retire();return}
        var snapshot:[MobileTouchKeys.Contact]=[]
        for (id,touch) in contacts.values {
            let point=touch.location(in:self)
            guard point.y>=0,point.y<=bounds.height else{retire();return}
            snapshot.append(.init(id:id,x:Double(point.x/bounds.width)))
        }
        guard let output=current.update(change,contacts:snapshot) else{retire();return}
        owner=current;changed?(output,true);setNeedsDisplay()
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){
        guard owner != nil else{return}
        guard contacts.count+touches.count<=MobileTouchKeys.maximumContacts else{retire();return}
        for touch in touches {
            let identity=ObjectIdentifier(touch)
            guard touch.type == .direct,contacts[identity]==nil else{retire();return}
            let used=Set(contacts.values.map{$0.0})
            guard let id=(0..<MobileTouchKeys.maximumContacts).first(where:{!used.contains($0)}) else{retire();return}
            contacts[identity]=(id,touch)
        }
        publish(.began)
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?){
        guard owner != nil else{return}
        guard touches.allSatisfy({contacts[ObjectIdentifier($0)] != nil}) else{retire();return}
        publish(.moved)
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?){
        guard owner != nil else{return}
        guard touches.allSatisfy({contacts[ObjectIdentifier($0)] != nil}) else{retire();return}
        for touch in touches{contacts.removeValue(forKey:ObjectIdentifier(touch))}
        publish(.ended)
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?){retire()}
    override func draw(_ rect:CGRect){
        super.draw(rect)
        let keys=(0..<13)
        let cell=bounds.width/CGFloat(keys.count)
        let mask=owner?.output.keys ?? 0
        for key in keys {
            let frame=CGRect(x:CGFloat(key)*cell+1,y:1,width:max(0,cell-2),height:max(0,bounds.height-2))
            let color:UIColor = mask & (1<<key) != 0 ? .systemBlue : owner==nil ? .systemGray3 : .systemGray6
            color.setFill();UIBezierPath(roundedRect:frame,cornerRadius:3).fill()
            let label=String(key+1) as NSString
            let attrs:[NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:min(14,cell*0.55)),.foregroundColor:UIColor.label]
            let size=label.size(withAttributes:attrs)
            label.draw(at:CGPoint(x:frame.midX-size.width/2,y:frame.maxY-size.height-8),withAttributes:attrs)
        }
    }
}
#endif

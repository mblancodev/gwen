"""Word tables for local punctuation (English and Spanish)."""
def _set(text):
    return frozenset(text.split())


def _phrases(text):
    """'i wonder|tell me' -> {("i", "wonder"), ("tell", "me")}"""
    return frozenset(tuple(p.split()) for p in text.split("|") if p.strip())


# Spoken commands with more than one word: taken wherever they're said, removed, and turned into their mark. A "?"
# kind only counts with its other half ("quote … end quote"): alone, "quote" and "unquote" are words. The one-word
# commands ("colon", "dash", "raya", "semicolon", "ellipsis", "guion") need a pause on both sides: P3, not here.
COMMANDS = [
    (r"open\s+quotes?|begin\s+quotes?", "q_open"), (r"(?:end|close)\s+quotes?", "q_close"),
    (r"abre\s+comillas|abrir\s+comillas", "q_open"), (r"(?:cierra|cierre|cerrar)\s+comillas", "q_close"),
    (r"open\s+(?:paren|parenthesis|parentheses)", "p_open"), (r"close\s+(?:paren|parenthesis|parentheses)", "p_close"),
    (r"abre\s+par[eé]ntesis|abrir\s+par[eé]ntesis", "p_open"), (r"(?:cierra|cierre|cerrar)\s+par[eé]ntesis", "p_close"),
    (r"open\s+brackets?", "b_open"), (r"close\s+brackets?", "b_close"),  # P6
    (r"abre\s+corchetes?|abrir\s+corchetes?", "b_open"), (r"(?:cierra|cierre|cerrar)\s+corchetes?", "b_close"),
    (r"in\s+parenthes[ie]s", "p_open?"), (r"entre\s+par[eé]ntesis", "p_open?"),
    (r"new\s+paragraph", "para"), (r"nuevo\s+p[aá]rrafo", "para"), (r"punto\s+y\s+aparte", "stop_para"),
    (r"new\s+line", "line"), (r"nueva\s+l[ií]nea", "line"),
    (r"dot\s+dot\s+dot", "..."), (r"puntos\s+suspensivos", "..."),
    (r"punto\s+y\s+coma", ";"), (r"dos\s+puntos", ":"),
    (r"unquote", "q_close?"), (r"quote", "q_open?"), (r"comillas", "q_open?"),
]

# "a new line", "the quote", "un punto y coma": a word that names the thing, not a command
DETERMINERS = _set("a an the this that each every another my your his her our their its any no "
                   "un una el la los las este esta ese esa aquel otro otra unos unas mi mis tu tus su sus nuestro "
                   "nuestra cada")
# "dos puntos" is also "two points": "tengo dos puntos importantes", "ganamos por dos puntos"
DOS_PUNTOS = {
    "before": _set("hay tengo tiene tenemos tienen son eran quedan faltan faltaban ganamos ganó perdimos perdió sacó "
                   "saqué sumó suma sumamos con por en de a y o los unos estos esos sus mis tus nuestros otros solo "
                   "sólo últimos primeros más menos apenas casi unos"),
    "after": _set("de del más menos que a en por para y o porque sobre extra arriba abajo atrás adelante importantes "
                  "clave principales básicos esenciales"),
}

# "e.g. the", "Mr. Smith": a period that ends no sentence
ABBREV = _set("mr mrs ms dr prof sr sra srta st vs etc e.g i.e a.m p.m approx ud uds núm dra ing lic")

EN = {
    "pronouns": _set("i you he she it we they"),
    "subjects": _set("i you he she it we they there this that these those the a an my your his her our their its "
                     "anyone anybody someone somebody everyone everybody something anything everything any some "
                     "all both"),
    # yes/no questions: one of these, then a subject. "Do", "have", "may" and "shall" only before a pronoun ("Do it",
    # "Have a nice day", "May the force…"); "should" and "were" only in a sentence with no comma ("Should you need
    # anything, call me"). "Had" is left out: "Had I known, …".
    "aux": _set("is are was were am do does did can could will would should shall may might must have has "
                "isn't aren't wasn't weren't doesn't didn't can't couldn't won't wouldn't shouldn't haven't hasn't"),
    "aux_pron": {"do": _set("i you we they"), "have": _set("i you we they"), "may": _set("i we"),
                 "shall": _set("i we")},
    "aux_nocomma": _set("should were"),
    "wh": _set("what where when why who whom whose which how"),
    "wh_short": _set("what's where's who's how's when's why's what're where're who're whats wheres hows"),
    "wh_short_not": _set("more done"),  # "What's more, …"
    "wh_phrase": _phrases("how come|what about|how about|what if|why not|what else"),
    "how_many": _set("many much"),
    "tags": _phrases("right|correct|isn't it|aren't you|aren't they|aren't we|don't you|don't they|don't we|"
                     "doesn't it|doesn't he|doesn't she|didn't you|didn't he|didn't she|didn't they|didn't it|"
                     "won't you|won't it|wasn't it|weren't you|haven't you|hasn't it|can't you|isn't that|"
                     "is it|are you|or not"),
    # "I wonder what…", "tell me how…": the question is embedded, the sentence is a statement
    "embed": _phrases("i wonder|i'm wondering|i am wondering|i was wondering|i don't know|i do not know|i dunno|"
                      "i'm not sure|i am not sure|not sure|i'm curious|i know|i forgot|i forget|i can't remember|"
                      "i don't remember|no idea|i have no idea|tell me|let me know|let's see|i need to know|"
                      "i want to know|ask him|ask her|ask them|i asked|i doubt|it depends on|depends on|"
                      "we need to figure out|i need to figure out|figure out|find out|let's find out"),
    "embed_wh": _set("what where when why who whom whose which how if whether"),
    "trail": _phrases("and|but|or|because|so"),
    "trail_guard": {"so": _set("think hope guess believe suppose imagine expect fear say said told tell do did "
                               "does not or and is was am are were be been more even just really quite ever i me "
                               "you it that"),
                    "because": _set("just"), "or": _set("either whether")},
    "openers": _phrases("by the way|in fact|for example|for instance|in other words|on the other hand|"
                        "first of all|in any case|anyway|anyways|besides|meanwhile|furthermore|moreover|"
                        "nevertheless|nonetheless|honestly|unfortunately|fortunately|basically|apparently"),
    "openers_subj": _phrases("so|well|okay|ok|alright|however"),
    "openers_pron": _phrases("yes|yeah|no"),
    "opener_guard": {"however": _set("much many long hard often far big small little good bad")},
    "opener_guard2": {"however": _set("want wants like likes wish please choose prefer look see say do put try")},
    "opener_skip": _set("and but so okay ok well also then now hey oh alright actually anyway"),
    "greet": _phrases("hi|hello|thanks|thank you|bye|goodbye|good morning|good afternoon|good evening|"
                      "good night|congratulations|sorry|cheers"),
    "interj": _phrases("wow|great|thanks|thank you|awesome|amazing|cool|nice|oh no|oops|yay|hooray|"
                       "congratulations|perfect|excellent|ouch|careful|watch out|look out|well done|good job"),
    "how_excl": _set("nice cool great beautiful lovely awful terrible sad funny weird strange kind sweet cute "
                     "amazing wonderful interesting embarrassing annoying rude exciting"),
    "but": "but",
    "contractions": _set("i'm it's there's that's we're you're they're he's she's i'll we'll you'll they'll i've "
                         "we've you've i'd we'd let's"),
    "but_guard": _set("not nothing all anything everything everyone everybody nobody anyone last and or no"),
    # the linking words that take "; …," between two full clauses
    "link": _phrases("however|therefore|nevertheless|nonetheless|consequently|moreover|furthermore"),
    "link_guard": _set("and or but so is was are were be the a an i we you he she they it not that which who"),
    "announce_list": _phrases("the following|as follows"),
    "announce_clause": _phrases("here's the plan|here's my plan|here's the thing|here's the deal|here's the idea|"
                                "here's my idea|here's the problem|here's the point|here's the question|"
                                "here is the plan|here is the thing|here is the deal|here is the problem"),
    "announce_example": _phrases("for example|for instance|namely"),
    "announce_demo": _set("these those"),
    "announce_any_noun": _phrases("the following"),  # "the following documents: …", a plural
    "announce_nouns": _set("things steps points items reasons options ways questions ideas problems issues tasks "
                           "changes rules words names people places"),
    "numbers": {"two": 2, "three": 3, "four": 4, "five": 5, "six": 6},
    "verbish": _set("is are was were will can should would have has had do does did be been am that of for in "
                    "about to with and or on at by from it you"),
    "time": _set("day days week weeks month months year years morning afternoon evening night time weekend today "
                 "tomorrow yesterday "
                 "monday tuesday wednesday thursday friday saturday sunday"),
    "conj": _set("and or"),
    # quotations: a reporting verb, then words that could stand alone
    "say": _set("said says replied replies answered answers shouted yelled whispered wrote writes goes"),
    "ask": _set("asked asks"),
    "reporters": _set("he she they someone somebody everyone everybody nobody"),
    "reporter_det": _set("the my our your his her their"),
    "cap_stop": _set("i then and but so also it this that there we you if when as what"),
    "sub_guard": _set("as what that whatever if when which who"),
    "objects": _set("me us him her them you"),
    # only direct speech starts this way: "she said let's go", "he said okay I'll do it". Not "I'm", "I'll": "my
    # boss said I can leave", "the doctor said I'm fine" are mostly indirect, about you (the model decides those)
    "direct": _set("let's don't please okay ok hey hi hello thanks sorry wow oh yes no"),
    "direct_not": _set("to for"),  # "she said hello to everyone", "he said no to the offer"
    "indirect": _set("that if whether"),
}

ES = {
    "pronouns": _set("yo tú tu él ella usted nosotros nosotras vosotros ellos ellas ustedes"),
    "subjects": _set("yo tú él ella usted nosotros nosotras ellos ellas ustedes el la los las un una unos unas "
                     "mi mis tu tus su sus este esta esto ese esa eso no ya me te se nos le les lo nunca también"),
    "wh": _set("qué cómo cuándo dónde adónde quién quiénes cuál cuáles cuánto cuánta cuántos cuántas"),
    "preps": _set("a de con en por para desde hasta sobre entre hacia"),
    # "¡Qué bueno!" against "¿Qué hora es?": qué and one of these is an exclamation
    "excl_words": _set("bueno buena bien rico rica lindo linda bonito bonita malo mala mal horror pena suerte asco "
                       "miedo susto alegría frío calor gusto raro rara increíble maravilla barbaridad vergüenza "
                       "locura genial chévere bacano bacán chimba guay fuerte triste tristeza emoción ilusión "
                       "lástima desastre delicia belleza hermoso hermosa cansancio sueño hambre emocionante "
                       "divertido chistoso gracioso feo fea bello bella"),
    "excl_more": _set("más tan"),
    "tags": _phrases("no|verdad|cierto|o no|sí o no|vale|eh"),
    "embed": _phrases("no sé|yo no sé|no se|me pregunto|dime|dígame|pregúntale|pregunta|le pregunté|"
                      "quiero saber|no recuerdo|no me acuerdo|no me acuerdo de|explícame|cuéntame|avísame|"
                      "no tengo idea de|ni idea de|ni idea|depende de|no estoy seguro de|no estoy segura de"),
    "embed_wh": _set("qué cómo cuándo dónde adónde quién quiénes cuál cuáles cuánto cuánta cuántos cuántas "
                     "si por para"),
    "trail": _phrases("y|e|o|ni|pero|porque|que|o sea"),
    "trail_guard": {"que": _set("lo"), "o": _set("sí")},
    "openers": _phrases("sin embargo|o sea|por cierto|de hecho|no obstante|por lo tanto|por otro lado|"
                        "por otra parte|en cambio|por ejemplo|en primer lugar|es decir|mejor dicho|en resumen|"
                        "en fin|por supuesto|la verdad"),
    "openers_subj": _phrases("bueno|vale"),
    "openers_pron": _phrases("sí|no|mira|oye"),
    "opener_guard": {"o sea": _set("que"), "la verdad": _set("es"), "por supuesto": _set("que")},
    "opener_guard2": {},
    "opener_skip": _set("y pero bueno entonces oye pues mira vale ah oh ay ahora"),
    "greet": _phrases("hola|gracias|muchas gracias|buenos días|buenas tardes|buenas noches|adiós|chao|chau|"
                      "felicidades|perdón|disculpa"),
    "interj": _phrases("qué bueno|qué bien|genial|gracias|muchas gracias|ojo|cuidado|ay|uy|guau|perfecto|"
                       "excelente|felicidades|enhorabuena|bravo|vaya|increíble|qué pena|ostras|madre mía|"
                       "dios mío|cuánto tiempo|qué chimba|qué chévere"),
    "but": "pero",
    "but_guard": _set("y o ni que a de sino mas pero"),
    "link": _phrases("sin embargo|por lo tanto|no obstante|por consiguiente|por ende"),
    "link_guard": _set("y o pero que es era fue el la los las un una yo no muy"),
    "announce_list": _phrases("lo siguiente|los siguientes|las siguientes"),
    "announce_clause": _phrases("este es el plan|esta es la idea|este es el problema|esta es la cosa"),
    "announce_example": _phrases("por ejemplo|a saber|es decir"),
    "announce_demo": _set("estos estas esos esas"),
    "announce_any_noun": _phrases("los siguientes|las siguientes"),
    "announce_nouns": _set("cosas pasos puntos razones opciones formas maneras preguntas ideas problemas tareas "
                           "cambios reglas palabras nombres personas lugares"),
    "numbers": {"dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6},
    "verbish": _set("es son era eran fue fueron está están estaba será serán va van hay tiene tienen me te se nos "
                    "que de para en con y o a al del por"),
    "time": _set("día días semana semanas mes meses año años mañana tarde noche vez lunes martes miércoles jueves "
                 "viernes sábado domingo"),
    "conj": _set("y e o u"),
    "subordinators": _set("si cuando aunque como porque mientras"),
    "say": _set("dijo dice decía dije respondió respondí contestó contesté gritó escribió comentó"),
    "ask": _set("preguntó pregunté preguntaba"),  # not "pregunta": "La pregunta es…"
    "clitics": _set("me te le nos les se"),
    "sub_guard": _set("que como según cuando si lo la los las el un una esta esa mi tu su otra donde quien quién "
                      "qué cómo"),
    # "dijo que…" is indirect; "dijo eso", "dijo la verdad", "le dijo a Juan" report no words
    "not_direct": _set("que si eso esto algo nada todo la el lo los las un una unos unas a al de del por para con "
                       "sobre en mentiras sí no adiós hola gracias cosas mucho poco muchas tantas varias pocas ayer hoy "
                       "antes después luego siempre nunca también tampoco bien mal más menos otra veces mil dos tres "
                       "cuatro cinco me te se le nos les qué cómo cuándo dónde quién cuál cuánto"),
}

WORDS = {"en": EN, "es": ES}

# Whisper's `prompt` for a dictation (P2): two lines with every mark, in the language you dictated in last (and in
# Spanish the spoken commands' names). The spike (2026-10-05) found it lifts . and , in both languages (with some
# extra marks) and doesn't pull the detected language toward the prompt's. Whisper reads it as text that came before,
# so it writes in that style: never words of yours.
WHISPER_PROMPTS = {
    "en": 'Well, here\'s the plan: first the report, then the call. Is that okay? Great!\n'
          'She said, "Let\'s go" (finally); I wasn\'t sure - and then... nothing.',
    "es": 'Bueno, este es el plan: primero el informe, luego la llamada. ¿Te parece bien? ¡Genial!\n'
          'Ella dijo: "Vámonos" (por fin); yo no estaba seguro - y luego... nada.\n'
          # the second spike run (2026-10-06): with the command names written out, Whisper heard 8 of the 16 said in
          # Spanish, not 3. In English it changed nothing (6 either way), and a line of ! : ; got none written.
          'Punto y aparte, nueva línea, abre comillas, cierra comillas, abre paréntesis, cierra paréntesis, dos puntos, '
          'punto y coma, raya, puntos suspensivos.',
}

# A guess at the language from the text alone, until Whisper says which (P2): a few words only one of them uses
HINTS = {
    "en": _set("the and is are you i to of it that what with this have was for not we they do can will my your "
               "he she there be been on at in just but so thanks please hello hi hey would should could don't i'm "
               "it's are was were has had did does or if then than when where why how who which will can't won't "
               "didn't doesn't isn't we're you're they're yes okay said"),
    "es": _set("el la los las que de y es en un una por para con se lo como pero qué está estoy yo tú mi "
               "gracias hola oye bueno muy también pues porque cuando eso esto aquí vamos tengo del al hay voy va son "
               "sí ya nos dijo tiene hacer quiero puedo eres soy están estás cómo dónde cuándo sin"),
}

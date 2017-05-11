const node = document.getElementById('app');
const app = Elm.Main.embed(node);

app.ports.getImgWidth.subscribe(function(selector) {
    getWidth(selector, 0, function (result) {
        app.ports.imgWidth.send(result);
    });
});

app.ports.printWindow.subscribe(function() {
    window.print();
});

app.ports.postProcessStory.subscribe(function (words) {
    renderStoryContent ("storycontent", words);
});

const getWidth = function (selector, count, callback) {
    var node = document.querySelector(selector);

    if (count > 10) {
        return callback(0);
    }

    if (!nullOrEmpty(node)) {
        return callback(node.naturalWidth);
    }

    setTimeout(function () {
        getWidth(selector, count + 1, callback);
    }, 5);

    return callback(0);
};

const nullOrEmpty = function (n) {
    return n === null || n === undefined || n.naturalWidth === 0;
};

const renderStoryContent = function (elt, words) {
    const wordIndex = function(word) {
        for(var w of words) {
            if (w.word === word) {
                return w.index;
            }
        }
        return -1;
    };

    const go = function () {
        var storyElt = document.getElementById(elt);

        if (!storyElt) {
            window.requestAnimationFrame(go);
        } else {
            var ems = storyElt.querySelectorAll('p em');
            for (var em of ems) {
                var w = em.innerText;
                var i = wordIndex(w);
                if (i < 0) {
                    continue;
                }
                em.innerHTML = '<span class="dict-lookup" data-index="' + i + '">' + em.innerText + '</span>';
                em.addEventListener('click', function () {
                    var span = this.querySelector('span');
                    var index = span.getAttribute('data-index');
                    app.ports.dictLookup.send([span.innerText, parseInt(index)]);
                });
            }
        }
    };
    go();
};

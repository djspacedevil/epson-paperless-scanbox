FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    sane-utils \
    libsane \
    sane-airscan \
    img2pdf \
    imagemagick \
    curl \
    dbus \
    avahi-daemon \
    avahi-utils \
    && rm -rf /var/lib/apt/lists/*

COPY poll_button.sh /poll_button.sh
COPY scan.sh        /scan.sh
COPY merge.sh       /merge.sh

RUN chmod +x /poll_button.sh /scan.sh /merge.sh

VOLUME ["/consume"]

CMD ["/poll_button.sh"]